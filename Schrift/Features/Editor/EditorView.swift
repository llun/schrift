import PhotosUI
import QuickLook
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
    return .syncedAgo(RelativeDateFormatterCache.shared.string(for: lastSyncedAt, relativeTo: now, locale: locale))
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
/// `isOffline` is the display signal (path, Work Offline or transport evidence); `controlsOffline` is
/// the controls signal (path down or Work Offline), which alone decides whether the retry is offered.
func syncCaption(
    hasUnsavedLocalContent: Bool,
    hasConflict: Bool,
    isOffline: Bool,
    controlsOffline: Bool,
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
        // handles it). "Offline" for the retry is the path/Work Offline signal
        // (`controlsOffline`), not the display one: transport evidence alone must not hide a
        // control, because tapping it is the only request that can observe the server
        // coming back.
        if case .pendingSync = saveState {
            return SyncCaption(text: .key(.editor_sync_pending_sync), offersRetry: !controlsOffline)
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
    @Environment(\.docsTheme) private var theme
    let offersRetry: Bool
    let text: String
    let retryAccessibilityLabel: String
    var onRetry: () -> Void

    var body: some View {
        if offersRetry {
            Button(action: onRetry) {
                Text(text)
                    .font(DocsFont.footnote)
                    .foregroundStyle(theme.colors.textBrand)
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
                .foregroundStyle(theme.colors.textTertiary)
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
/// the editing gate is gone. `isOffline` only hides Share. What keeps Edit safe
/// on a document whose content never loaded is
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

/// Share addresses the server's copy, so it is hidden for local documents and while
/// offline. Edit/Done and Options remain reachable for durable local work.
func editorToolbarActions(isEditing: Bool, isLocal: Bool = false, isOffline: Bool = false) -> [EditorToolbarAction] {
    var actions: [EditorToolbarAction] = [isEditing ? .done : .edit]
    if !isLocal && !isOffline { actions.append(.share) }
    actions.append(.options)
    return actions
}

/// Holds the editor's other presentations back while the outline sheet is on screen.
///
/// The outline keeps the canvas, the toolbar and the formatting bar interactive behind it, so
/// anything can ask to present meanwhile: Share and Options, the Pages drawer, the formatting bar's
/// link and attach buttons, the slash menu's Photo and File, a link's Edit, a sub-page row's Move
/// and Delete, a sync conflict, an attachment card's QuickLook preview (handed up through
/// `AttachmentPreviewAction`). Navigation away from the document is held the same way, by
/// `OutlineHeldNavigation`. SwiftUI shows one presentation at a time, so any of them presented
/// over the outline would silently fail (leaving its flag set, so the next attempt does nothing) or
/// pop up later. Instead every request stays set but is *held*: the outline is asked to close, and
/// once its sheet has finished dismissing the request is released and presents. Nothing is reset,
/// so no request is dropped, and a slash command's consumed "/photo" still opens its picker.
struct OutlinePresentationGate: Equatable {
    /// From the moment the outline sheet appears until it has finished dismissing. Set on
    /// appearance rather than on request, so an outline that never managed to present cannot
    /// hold everything else back for good.
    private(set) var isOutlineOnScreen = false

    mutating func outlineAppeared() { isOutlineOnScreen = true }
    mutating func outlineDismissed() { isOutlineOnScreen = false }

    /// Whether a requested presentation may come up now.
    func releases(_ isRequested: Bool) -> Bool {
        isRequested && !isOutlineOnScreen
    }

    /// The item an item-driven presentation may show now: `nil` while it is held.
    func release<Item>(_ item: Item?) -> Item? {
        isOutlineOnScreen ? nil : item
    }

    /// Whether the outline should close because something else asked to present.
    func closesOutline(hasPendingRequest: Bool) -> Bool {
        hasPendingRequest && isOutlineOnScreen
    }
}

/// A navigation away from this document, held until the outline sheet has gone.
///
/// The outline is a sheet on this screen, and this screen stays alive underneath a pushed
/// document, so a push made while the outline is up (a page chip or a Subpages row tapped on the
/// canvas behind it) would leave the outline over the new document, listing the old one's
/// headings. Instead the destination is held, the outline closes, and the destination is handed
/// back from the outline's `onDismiss`. With the outline not on screen it goes straight through.
struct OutlineHeldNavigation<Destination> {
    private(set) var pending: Destination?

    var isHolding: Bool { pending != nil }

    /// The destination to navigate to now, or `nil` when it is held until the outline has dismissed.
    /// A newer request replaces a held one: only the last tap is followed.
    mutating func request(_ destination: Destination, isOutlineOnScreen: Bool) -> Destination? {
        guard isOutlineOnScreen else {
            pending = nil
            return destination
        }
        pending = destination
        return nil
    }

    /// The held destination, now that the outline has finished dismissing. Handed out once.
    mutating func takeAfterOutlineDismissed() -> Destination? {
        defer { pending = nil }
        return pending
    }
}

/// Where the editor sends the user when they leave this document for another one.
enum EditorNavigation {
    /// An existing document: a page chip, a Subpages row or a drawer row.
    case open(Document)
    /// A page just created here: "Add a page" or the drawer's New page.
    case created(Document)
}

/// How many peers to present, or `nil` when presence should not be shown at all.
///
/// Offline suppresses it: peer state is whatever the socket last said, and
/// presenting a stale count as live would be a small lie.
///
/// Availability follows the current network path and Work Offline preference.
func presentedPeerCount(peerCount: Int, isOffline: Bool) -> Int? {
    guard !isOffline, peerCount > 0 else { return nil }
    return peerCount
}

/// Presents the unified document shell (navigation bar actions, banner stack,
/// conflict resolution, Pages drawer, Options, Share, subpages, and offline/delete
/// chrome) across `.loading`, `.native`, `.preservedUnavailable`, and `.classic`.
struct EditorView: View {
    @Environment(\.docsTheme) private var theme
    @Environment(NativeSessionRegistry.self) private var nativeSessions: NativeSessionRegistry?
    @Environment(DocumentCollaborationManager.self) private var collaboration: DocumentCollaborationManager?
    @Environment(LocalizationStore.self) private var loc
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Followed while open: a native document leaves or rejoins its room (PR09b).
    @AppStorage(LiveCollaborationPreference.key) private var liveCollaboration = false

    @Bindable var viewModel: EditorViewModel
    let reach: LinkReach
    let serverHost: String
    let serverOrigin: String
    var childrenCache: DocumentChildrenCacheStore = DocumentChildrenCacheStore()
    var linkRole: LinkRole? = nil
    var initialIsFavorite: Bool = false
    var pinRow: Document? = nil
    var isOffline: Bool = false
    var onDeleted: (() -> Void)? = nil
    var onOpenDocument: ((Document) -> Void)? = nil
    var onCreatedDocument: ((Document) -> Void)? = nil
    /// `SessionStore.signInGeneration`: a change means the session under this
    /// screen may be another account's, so the native route is closed and
    /// reopened rather than left typing into the previous account's replica.
    var signInGeneration: Int = 0

    @State private var nativeOpen = NativeEditorOpen()
    @State private var mentionLoader: NativeMentionAccessLoader?
    @State private var offlineBannerStatus = DebouncedStatus()
    @State private var isPresentingShareSheet = false
    @State private var isPresentingOptionsSheet = false
    @State private var isPresentingOutline = false
    @State private var pendingOutlineAfterOptions = false
    @State private var pendingShareAfterOptions = false
    @State private var outlineGate = OutlinePresentationGate()
    @State private var outlineHeldNavigation = OutlineHeldNavigation<EditorNavigation>()
    @State private var outlineFocusesFind = false
    @State private var outlineScrollRequest: DocumentScrollRequest?
    @State private var conflictToResolve: IdentifiedSyncConflict?
    @State private var toastMessage: ToastMessage?
    @State private var isPresentingPagesTree = false
    @State private var documentPendingUndo: Document?
    @State private var subpagePendingDeleteConfirmation: Document?
    @State private var drawerPendingDeleteConfirmation: Document?
    @State private var documentPendingMove: Document?
    @State private var subpageSwipe = SwipeRevealState<UUID>()
    @State private var scrollAnchor = EditorScrollAnchorStore()
    @State private var readingPosition: ReadingPositionSession
    @State private var attachmentPreviewURL: URL?
    @State private var pagesTreeViewModel: PagesTreeViewModel
    @State private var optionsViewModel: OptionsViewModel
    @State private var shareViewModel: ShareViewModel

    /// Height the formatting bar reserves at the bottom of the canvas:
    /// its 44pt tap target plus the inset's own padding.
    private var editingToastInset: CGFloat { DocsSpacing.rowMinHeight + DocsSpacing.spaceBase }

    private var showsOffline: Bool { isOffline || viewModel.availability.isOffline }
    private var showsOfflineStatus: Bool { isOffline || viewModel.availability.showsOfflineStatus }
    private var showsOfflineBanner: Bool {
        isOffline || viewModel.availability.isWorkOffline || offlineBannerStatus.value
    }

    private var isClassicRoute: Bool {
        if case .classic = nativeOpen.route { return true }
        return false
    }

    private var toastBottomInset: CGFloat {
        switch nativeOpen.route {
        case .classic:
            return viewModel.isEditing ? editingToastInset : 0
        case .native(let session):
            return session.input != nil ? editingToastInset : 0
        case .loading, .preservedUnavailable:
            return 0
        }
    }

    init(
        viewModel: EditorViewModel,
        reach: LinkReach,
        serverHost: String,
        serverOrigin: String,
        childrenCache: DocumentChildrenCacheStore = DocumentChildrenCacheStore(),
        linkRole: LinkRole? = nil,
        initialIsFavorite: Bool = false,
        pinRow: Document? = nil,
        isOffline: Bool = false,
        onDeleted: (() -> Void)? = nil,
        onOpenDocument: ((Document) -> Void)? = nil,
        onCreatedDocument: ((Document) -> Void)? = nil,
        signInGeneration: Int = 0
    ) {
        self._viewModel = Bindable(viewModel)
        self.reach = reach
        self.serverHost = serverHost
        self.serverOrigin = serverOrigin
        self.childrenCache = childrenCache
        self.linkRole = linkRole
        self.initialIsFavorite = initialIsFavorite
        self.pinRow = pinRow
        self.isOffline = isOffline
        self.onDeleted = onDeleted
        self.onOpenDocument = onOpenDocument
        self.onCreatedDocument = onCreatedDocument
        self.signInGeneration = signInGeneration
        _readingPosition = State(
            initialValue: ReadingPositionSession(serverOrigin: serverOrigin, documentID: viewModel.documentID))
        _optionsViewModel = State(
            initialValue: OptionsViewModel(
                client: viewModel.client, documentID: viewModel.documentID, isFavorite: initialIsFavorite,
                saveCoordinator: viewModel.saveCoordinator, signedInUser: viewModel.signedInUser, pinRow: pinRow))
        _shareViewModel = State(
            initialValue: ShareViewModel(
                client: viewModel.client, documentID: viewModel.documentID, linkReach: reach, linkRole: linkRole))
        _pagesTreeViewModel = State(
            initialValue: PagesTreeViewModel(
                rootID: viewModel.documentID, client: viewModel.client, cache: childrenCache,
                saveCoordinator: viewModel.saveCoordinator, signedInUser: viewModel.signedInUser))
    }

    var body: some View {
        shellContent
            .modifier(shellOverlaysModifier)
            .toolbar { shellToolbar }
            .navigationBarTitleDisplayMode(.inline)
            .task { await openNative() }
            .onAppear {
                viewModel.noteEditorAppeared()
            }
            .onDisappear {
                nativeOpen.flushPendingSave()
                nativeOpen.close()
                mentionLoader?.reset()
            }
            .onChange(of: viewModel.availability.transportOfflineEvidence, initial: true) { _, raw in
                offlineBannerStatus.update(raw)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background || phase == .inactive { nativeOpen.flushPendingSave() }
            }
            .onChange(of: viewModel.availability.token) { _, _ in
                if viewModel.availability.isOffline {
                    viewModel.pauseLoadingWhileOffline()
                    isPresentingShareSheet = false
                    pendingShareAfterOptions = false
                }
            }
            .onChange(of: showsOffline) { _, offline in
                syncMentionLoader()
                if offline {
                    isPresentingShareSheet = false
                    pendingShareAfterOptions = false
                }
                if case .native(let session) = nativeOpen.route {
                    session.input?.refreshInlinePicker()
                }
                guard !offline else { return }
                nativeOpen.refreshInBackground(viewModel: viewModel, isOffline: showsOffline)
                if !isClassicRoute {
                    Task { await viewModel.loadChildren() }
                }
            }
            .onChange(of: liveCollaboration) { _, _ in
                nativeOpen.liveSettingChanged(viewModel: viewModel, isOffline: showsOffline)
            }
            .onChange(of: signInGeneration) { _, _ in
                syncMentionLoader()
                // A mounted classic editor keeps its own session handling and is never swapped.
                if case .classic = nativeOpen.route { return }
                nativeOpen.reopen(
                    viewModel: viewModel, isOffline: showsOffline,
                    canUpdate: pinRow?.abilities.update == true,
                    canMention: pinRow?.abilities.mention == true)
            }
            .onChange(of: nativeOpen.canMention) { _, _ in
                syncMentionLoader()
                if case .native(let session) = nativeOpen.route {
                    session.input?.refreshInlinePicker()
                }
            }
            .onChange(of: viewModel.signedInUser.userID) { _, _ in
                syncMentionLoader()
                if case .native(let session) = nativeOpen.route {
                    session.input?.refreshInlinePicker()
                }
            }
            .onChange(of: viewModel.isLocalDocument) { _, _ in
                syncMentionLoader()
                if case .native(let session) = nativeOpen.route {
                    session.input?.refreshInlinePicker()
                }
            }
    }

    private var shellContent: some View {
        VStack(spacing: 0) {
            bannerStack
            routeBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.attachmentPreview, AttachmentPreviewAction { attachmentPreviewURL = $0 })
        .quickLookPreview(heldForOutline($attachmentPreviewURL))
        .pendingDeleteUndoAlert(for: heldForOutline($documentPendingUndo)) { document in
            viewModel.undoPendingDelete(document)
        }
        .deleteConfirmationAlert(
            for: heldForOutline($subpagePendingDeleteConfirmation),
            hasLocalSubpages: { viewModel.hasLocalSubpages($0) }
        ) { document in
            Task { await viewModel.deleteSubpage(document) }
        }
        .deleteConfirmationAlert(
            for: heldForOutline($drawerPendingDeleteConfirmation),
            hasLocalSubpages: { viewModel.hasLocalSubpages($0) }
        ) { document in
            Task { await pagesTreeViewModel.deletePage(document) }
        }
    }

    private var shellOverlaysModifier: some ViewModifier {
        EditorShellOverlaysModifier(
            client: viewModel.client,
            saveCoordinator: viewModel.saveCoordinator,
            signedInUser: viewModel.signedInUser,
            theme: theme,
            toastBottomInset: toastBottomInset,
            presentsPagesTree: presentsPagesTree,
            isOffline: isOffline,
            isPresentingShareSheet: heldForOutline($isPresentingShareSheet),
            isPresentingOptionsSheet: heldForOutline($isPresentingOptionsSheet),
            pendingShareAfterOptions: $pendingShareAfterOptions,
            pendingOutlineAfterOptions: $pendingOutlineAfterOptions,
            conflictToResolve: heldForOutline($conflictToResolve),
            documentPendingMove: heldForOutline($documentPendingMove),
            toastMessage: $toastMessage,
            pagesDrawerPresentation: pagesDrawerPresentation,
            shareSheet: { shareSheet },
            optionsSheet: { optionsSheet },
            presentOutlineAfterOptions: { presentOutline(focusingFind: false) },
            onKeepMine: { resolveConflictKeepingMine() },
            onKeepServer: { Task { await resolveConflictKeepingServer() } }
        )
    }

    @ViewBuilder
    private var routeBody: some View {
        switch nativeOpen.route {
        case .loading:
            EditorLoadingPlaceholder()
        case .native(let session):
            NativeEditorView(
                session: session, title: viewModel.title, serverOrigin: serverOrigin,
                preservedNotice: nativeOpen.isPreservedReadOnly
                    ? .native_editor_owned_read_only_body : nil,
                saveStatus: session.input == nil ? nil : nativeSaveStatus(session),
                saveFailureDetail: viewModel.saveFailureDetail,
                saveFailureOffersRetry: viewModel.saveFailureOffersRetry,
                onSave: { nativeOpen.saveNow(viewModel: viewModel) }, isOffline: showsOffline,
                documentID: viewModel.documentID,
                uploadDocumentID: viewModel.isLocalDocument ? nil : viewModel.documentID,
                mediaQueue: viewModel.saveCoordinator,
                documentTitle: { [viewModel] id in viewModel.cachedDocumentTitle(for: id) },
                resolveLinkedDocument: { [viewModel] id in await viewModel.openLinkedDocument(id) },
                onOpenDocument: onOpenDocument,
                inlinePickerSource: makeInlinePickerSource(),
                showsStandaloneChrome: false,
                headerContent: { AnyView(nativeHeader(session)) },
                footerContent: { AnyView(nativeSubpagesFooter) },
                externalOutlinePresented: $isPresentingOutline,
                externalOutlineFocusesFind: $outlineFocusesFind,
                outlineShortcutEnabled: !viewModel.isLoading && !hasPendingPresentation,
                outlineClosesOutline: outlineGate.closesOutline(hasPendingRequest: hasPendingPresentation),
                onOutlineAppear: { outlineGate.outlineAppeared() },
                onOutlineDismiss: {
                    outlineGate.outlineDismissed()
                    if let held = outlineHeldNavigation.takeAfterOutlineDismissed() { perform(held) }
                },
                onScrollInteraction: { subpageSwipe = swipeRevealAfterScrollInteraction(subpageSwipe) })
        case .preservedUnavailable:
            preservedUnavailableView
        case .classic:
            ClassicEditorView(
                viewModel: viewModel, reach: reach,
                canUpdateLiveDocument: pinRow?.abilities.update == true,
                serverHost: serverHost, serverOrigin: serverOrigin,
                offlineOverride: isOffline,
                canOpenDocuments: onOpenDocument != nil,
                outlineScrollRequest: $outlineScrollRequest,
                isPresentingOutline: $isPresentingOutline,
                outlineFocusesFind: $outlineFocusesFind,
                outlineGate: $outlineGate,
                outlineHeldNavigation: $outlineHeldNavigation,
                hasPendingPresentation: hasPendingPresentation,
                scrollAnchor: scrollAnchor,
                readingPosition: $readingPosition,
                subpageSwipe: $subpageSwipe,
                documentPendingUndo: $documentPendingUndo,
                subpagePendingDeleteConfirmation: $subpagePendingDeleteConfirmation,
                documentPendingMove: $documentPendingMove,
                onNavigate: navigate,
                onPerformNavigation: perform,
                onPresentOutline: presentOutline)
        }
    }

    @ViewBuilder
    private var preservedUnavailableView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EditorBlockMetrics.blockSpacing) {
                EditorDocumentHeader(
                    title: viewModel.title, onEditTitle: nil, reach: reach, peers: []
                ) {
                    nativeHeaderStatus(session: nil)
                }
                .padding(.bottom, EditorBlockMetrics.headerToBodySpacing - EditorBlockMetrics.blockSpacing)

                ContentUnavailableView(
                    loc[.native_editor_owned_unavailable_title], systemImage: "doc.richtext",
                    description: Text(loc[.native_editor_owned_unavailable_body]))

                subpagesSectionView
                    .padding(.top, EditorBlockMetrics.headerToBodySpacing - EditorBlockMetrics.blockSpacing)
            }
            .padding(.horizontal, EditorBlockMetrics.gutter)
            .padding(.top, DocsSpacing.spaceSM)
            .padding(.bottom, DocsSpacing.spaceLG)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func nativeHeader(_ session: NativeEditorSession) -> some View {
        let rawPeers = session.awareness?.peers ?? []
        let peers = presentedPeerCount(peerCount: rawPeers.count, isOffline: isOffline) == nil ? [] : rawPeers
        return EditorDocumentHeader(
            title: viewModel.title,
            onEditTitle: session.input != nil
                ? { nativeOpen.updateTitle($0, viewModel: viewModel) }
                : nil,
            reach: reach,
            peers: peers
        ) {
            nativeHeaderStatus(session: session)
        }
        .padding(.horizontal, EditorBlockMetrics.gutter)
        .padding(.top, DocsSpacing.spaceSM)
        .padding(.bottom, DocsSpacing.spaceXS)
    }

    private var nativeSubpagesFooter: some View {
        subpagesSectionView
            .padding(.horizontal, EditorBlockMetrics.gutter)
            .padding(.bottom, DocsSpacing.spaceLG)
    }

    @ViewBuilder
    private func nativeHeaderStatus(session: NativeEditorSession?) -> some View {
        let hasUnsaved = viewModel.isNativeLocalContentUnsaved(
            sessionHasPendingSave: session?.hasPendingSave ?? false)
        if let session, session.input != nil {
            let display = nativeSaveStatus(session)
            if display == .none {
                EditorSyncCaptionLabel(
                    viewModel: viewModel, offlineOverride: isOffline,
                    hasUnsavedOverride: hasUnsaved,
                    onRetry: { nativeOpen.saveNow(viewModel: viewModel) })
            } else {
                SaveStatusIndicator(
                    display: display, failureDetail: viewModel.saveFailureDetail,
                    failureOffersRetry: viewModel.saveFailureOffersRetry,
                    onTap: { nativeOpen.saveNow(viewModel: viewModel) })
            }
        } else {
            EditorSyncCaptionLabel(
                viewModel: viewModel, offlineOverride: isOffline,
                hasUnsavedOverride: hasUnsaved,
                onRetry: { nativeOpen.saveNow(viewModel: viewModel) })
        }
    }

    private var subpagesSectionView: some View {
        EditorSubpagesSection(
            viewModel: viewModel,
            subpageSwipe: $subpageSwipe,
            documentPendingUndo: $documentPendingUndo,
            subpagePendingDeleteConfirmation: $subpagePendingDeleteConfirmation,
            documentPendingMove: $documentPendingMove,
            onNavigate: navigate)
    }

    @ToolbarContentBuilder
    private var shellToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                isPresentingPagesTree = true
            } label: {
                ToolbarIcon(.account_tree)
            }
            .buttonBorderShape(.circle)
            .accessibilityLabel(loc[.pages_open])
            .accessibilityHidden(presentsPagesTree)
        }
        ToolbarItem(placement: .topBarTrailing) {
            toolbarButton(for: isClassicRoute && viewModel.isEditing ? .done : .edit)
                .accessibilityHidden(presentsPagesTree)
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        if editorToolbarActions(
            isEditing: isClassicRoute && viewModel.isEditing, isLocal: viewModel.isLocalDocument, isOffline: isOffline
        ).contains(.share) {
            ToolbarItem(placement: .topBarTrailing) {
                toolbarButton(for: .share)
                    .accessibilityHidden(presentsPagesTree)
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        ToolbarItem(placement: .topBarTrailing) {
            toolbarButton(for: .options)
                .accessibilityHidden(presentsPagesTree)
        }
    }

    @ViewBuilder
    private func toolbarButton(for action: EditorToolbarAction) -> some View {
        switch action {
        case .edit:
            Button {
                guard isClassicRoute else { return }
                snapshotScrollForModeSwap()
                viewModel.startEditing()
            } label: {
                ToolbarIcon(.edit)
            }
            .disabled(!isClassicRoute || !viewModel.canStartEditing)
            .buttonBorderShape(.circle)
            .accessibilityLabel(loc[.editor_action_edit])

        case .done:
            Button {
                guard isClassicRoute else { return }
                snapshotScrollForModeSwap()
                viewModel.finishEditing()
            } label: {
                ToolbarIcon(.check, filled: true)
            }
            .buttonBorderShape(.circle)
            .accessibilityLabel(loc[.editor_action_done])

        case .share:
            Button {
                guard !isOffline else { return }
                isPresentingShareSheet = true
            } label: {
                ToolbarIcon(.share)
            }
            .buttonBorderShape(.circle)
            .accessibilityLabel(loc[.editor_action_share])

        case .options:
            Button {
                isPresentingOptionsSheet = true
            } label: {
                ToolbarIcon(.more_horiz)
            }
            .buttonBorderShape(.circle)
            .accessibilityLabel(loc[.editor_action_options])
        }
    }

    private var bannerStack: some View {
        VStack(spacing: 0) {
            if showsOfflineBanner, viewModel.hasLocalCopy {
                OfflineBanner(note: loc[.editor_offline_local_copy])
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if viewModel.syncConflict != nil {
                Button {
                    dismissFocusForConflictSheet()
                    conflictToResolve = viewModel.syncConflict.map(IdentifiedSyncConflict.init)
                } label: {
                    EditorNoticeLabel(
                        icon: .warning, title: loc[.editor_conflict_pill], foreground: theme.colors.danger)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.top, DocsSpacing.spaceXS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(loc[.editor_conflict_pill_a11y])
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if isClassicRoute, viewModel.updateAvailable, !viewModel.isEditing {
                Button {
                    viewModel.applyPendingUpdate()
                } label: {
                    EditorNoticeLabel(
                        icon: .sync, title: loc[.editor_update_available], foreground: theme.colors.textBrand)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.top, DocsSpacing.spaceXS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(loc[.editor_update_available_a11y])
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if viewModel.isDocumentPendingDelete {
                pendingDeleteNotice
            } else if let errorKey = viewModel.errorKey {
                VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
                    Text(loc[errorKey])
                        .font(DocsFont.footnote)
                        .foregroundStyle(theme.colors.danger)
                    if let errorDetail = viewModel.errorDetail {
                        Text(errorDetail)
                            .font(DocsFont.footnote)
                            .foregroundStyle(theme.colors.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.top, DocsSpacing.spaceXS)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: showsOfflineBanner)
        .animation(reduceMotion ? nil : .snappy, value: viewModel.syncConflict != nil)
        .animation(reduceMotion ? nil : .snappy, value: viewModel.updateAvailable)
        .animation(reduceMotion ? nil : .snappy, value: viewModel.errorKey)
    }

    private var pendingDeleteNotice: some View {
        VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
            Text(loc[.editor_pending_delete])
                .font(DocsFont.footnote)
                .foregroundStyle(theme.colors.textSecondary)
            DocsButton(title: loc[.pending_delete_undo], variant: .secondary, size: .medium) {
                viewModel.undoPendingDeleteForThisDocument()
                Task {
                    if isClassicRoute {
                        await viewModel.load()
                    } else {
                        await reopenNativeAfterUndo()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DocsSpacing.gutter)
        .padding(.top, DocsSpacing.spaceXS)
    }

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
            availability: viewModel.availability,
            onLinkCopied: { toastMessage = ToastMessage(loc[.toast_link_copied]) },
            onShare: { pendingShareAfterOptions = true },
            onOutline: { pendingOutlineAfterOptions = true },
            onDeleted: { queued in
                if queued {
                    viewModel.handleDidQueueDelete()
                } else {
                    viewModel.noteDeletedFromThisScreen()
                }
                onDeleted?()
            }
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var hasPendingPresentation: Bool {
        isPresentingShareSheet || isPresentingOptionsSheet || isPresentingPagesTree
            || documentPendingMove != nil || subpagePendingDeleteConfirmation != nil
            || drawerPendingDeleteConfirmation != nil || documentPendingUndo != nil || conflictToResolve != nil
            || viewModel.linkEditor != nil || viewModel.isPhotoPickerPresented
            || viewModel.isAttachmentImporterPresented || attachmentPreviewURL != nil
            || outlineHeldNavigation.isHolding
    }

    private func heldForOutline(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { outlineGate.releases(binding.wrappedValue) }, set: { binding.wrappedValue = $0 })
    }

    private func heldForOutline<Item>(_ binding: Binding<Item?>) -> Binding<Item?> {
        Binding(get: { outlineGate.release(binding.wrappedValue) }, set: { binding.wrappedValue = $0 })
    }

    private var presentsPagesTree: Bool { outlineGate.releases(isPresentingPagesTree) }

    private var pagesDrawerPresentation: some ViewModifier {
        PagesDrawerPresentation(
            isPresented: Binding(get: { presentsPagesTree }, set: { isPresentingPagesTree = $0 }),
            isGestureEnabled: !hasPendingPresentation && !isPresentingOutline,
            onPresentedByDrag: { AccessibilityNotification.ScreenChanged().post() }
        ) { progress, pan in
            pagesTreeDrawer(progress: progress, pan: pan)
        }
    }

    private func pagesTreeDrawer(progress: CGFloat, pan: PagesDrawerPanHandlers) -> some View {
        PagesTreeDrawer(
            viewModel: pagesTreeViewModel,
            rootTitle: viewModel.title.isEmpty ? loc[.common_untitled] : viewModel.title,
            onOpen: { document in
                guard !viewModel.isDeletePending(document) else {
                    isPresentingPagesTree = false
                    documentPendingUndo = document
                    return
                }
                isPresentingPagesTree = false
                navigate(.open(document))
            },
            onCreated: { document in
                dismissPagesTree()
                navigate(.created(document))
            },
            onClose: { dismissPagesTree() },
            onRequestDelete: { document in
                dismissPagesTree()
                drawerPendingDeleteConfirmation = document
            },
            onRequestMove: { document in
                dismissPagesTree()
                documentPendingMove = document
            },
            onUndoPendingDelete: { document in
                dismissPagesTree()
                documentPendingUndo = document
            },
            progress: progress,
            pan: pan
        )
        .task {
            if presentsPagesTree { AccessibilityNotification.ScreenChanged().post() }
            guard !viewModel.isDocumentPendingDelete else { return }
            await pagesTreeViewModel.loadRoot()
        }
    }

    private func dismissPagesTree() {
        isPresentingPagesTree = false
        AccessibilityNotification.ScreenChanged().post()
    }

    private func navigate(_ navigation: EditorNavigation) {
        isPresentingOutline = false
        if let now = outlineHeldNavigation.request(navigation, isOutlineOnScreen: outlineGate.isOutlineOnScreen) {
            perform(now)
        }
    }

    private func perform(_ navigation: EditorNavigation) {
        switch navigation {
        case .open(let document): onOpenDocument?(document)
        case .created(let document): onCreatedDocument?(document)
        }
    }

    private func presentOutline(focusingFind: Bool) {
        if isPresentingPagesTree { dismissPagesTree() }
        outlineFocusesFind = focusingFind
        isPresentingOutline = true
    }

    private func snapshotScrollForModeSwap() {
        readingPosition.dismissBackToTop()
        readingPosition.cancelPendingRestore()
        guard viewModel.checklistReadingPresentation.hasChecklistItems || viewModel.hidesCompletedChecklistItems else {
            scrollAnchor.snapshotForSwap()
            return
        }
        let allIDs = viewModel.blocks.map(\.id)
        let readingIDs = ChecklistReadingPresentation(
            blocks: viewModel.blocks, hidingCompleted: viewModel.hidesCompletedChecklistItems,
            settling: viewModel.checklistSettling.ids
        ).rows.map(\.id)
        scrollAnchor.snapshotForSwap(
            blockOrder: viewModel.isEditing ? allIDs : readingIDs,
            restoringAmong: viewModel.isEditing ? readingIDs : allIDs)
    }

    private func dismissFocusForConflictSheet() {
        viewModel.dismissFocusForSheet()
        if case .native(let session) = nativeOpen.route {
            session.textView.resignFirstResponder()
        }
    }

    private func resolveConflictKeepingMine() {
        switch nativeOpen.route {
        case .native, .preservedUnavailable:
            nativeOpen.resolveConflictKeepingMine(viewModel: viewModel)
        case .loading, .classic:
            viewModel.resolveConflictKeepingMine()
        }
    }

    private func resolveConflictKeepingServer() async {
        switch nativeOpen.route {
        case .native, .preservedUnavailable:
            await nativeOpen.resolveConflictKeepingServer(
                viewModel: viewModel,
                isOffline: showsOffline,
                canUpdate: pinRow?.abilities.update == true,
                canMention: pinRow?.abilities.mention == true)
        case .loading, .classic:
            await viewModel.resolveConflictKeepingServer()
        }
    }

    private func openNative() async {
        syncMentionLoader()
        if let nativeSessions { nativeOpen.registry = nativeSessions }
        nativeOpen.collaboration = collaboration
        await nativeOpen.open(
            viewModel: viewModel, isOffline: showsOffline,
            canUpdate: pinRow?.abilities.update == true,
            canMention: pinRow?.abilities.mention == true)
        syncMentionLoader()
        if !isClassicRoute {
            await viewModel.loadChildren()
        }
    }

    private func reopenNativeAfterUndo() async {
        nativeOpen.close()
        await openNative()
    }

    private var currentMentionScope: NativeMentionAccessLoader.Scope {
        NativeMentionAccessLoader.Scope(
            serverOrigin: serverOrigin,
            ownerUserID: viewModel.signedInUser.userID,
            documentID: viewModel.documentID,
            signInGeneration: signInGeneration)
    }

    private func syncMentionLoader() {
        let scope = currentMentionScope
        let canMention = nativeOpen.canMention
        let isLocal = viewModel.isLocalDocument
        let offline = showsOffline
        if let mentionLoader {
            mentionLoader.update(
                scope: scope, canMention: canMention, isLocalDocument: isLocal, isOffline: offline)
        } else {
            mentionLoader = NativeMentionAccessLoader(
                client: viewModel.client, scope: scope, canMention: canMention,
                isLocalDocument: isLocal, isOffline: offline)
        }
    }

    private func makeInlinePickerSource() -> NativeInlinePickerSource {
        let loader = mentionLoader
        let serverOrigin = self.serverOrigin
        return NativeInlinePickerSource(
            canInsertPageLink: { !documentLinkHost(forOrigin: serverOrigin).isEmpty },
            pageLinkCandidates: { [viewModel] in viewModel.nativePageLinkCandidates() },
            excludedDocumentID: viewModel.documentID,
            onRecordDocumentTitle: { [viewModel] id, title in
                viewModel.recordNativeDocumentTitle(title, for: id)
            },
            canMention: { [nativeOpen, viewModel] in
                nativeOpen.canMention && !viewModel.isLocalDocument && viewModel.signedInUser.userID != nil
            },
            mentionState: { loader?.state ?? .idle },
            requestMentions: { key in
                loader?.requestMentions(for: key)
            },
            clearMentionFailure: {
                loader?.clearFailure()
            })
    }

    /// The classic status resolver, fed by the coordinator's real save state.
    /// Debounced journal bytes and unpushed title edits count as saved on device.
    private func nativeSaveStatus(_ session: NativeEditorSession) -> SaveStatusDisplay {
        if session.hasPendingSave || viewModel.hasPendingNativeTitleEdit { return .savedOnDevice }
        let hasConflict = viewModel.syncConflict != nil
        return saveStatusDisplay(
            saveState: viewModel.saveState, hasConflict: hasConflict,
            hasUnsavedLocalContent: hasConflict
                && viewModel.saveCoordinator.storedDraft(documentID: viewModel.documentID) != nil,
            connectionDown: isOffline || viewModel.availability.connectionAppearsDown)
    }
}

/// Extracted from `EditorView.body` to keep SwiftUI type-checking bounded.
private struct EditorShellOverlaysModifier<ShareSheet: View, OptionsSheet: View>: ViewModifier {
    let client: DocsAPIClient
    let saveCoordinator: DocumentSaveCoordinator
    let signedInUser: SignedInUserStore
    let theme: AppTheme
    let toastBottomInset: CGFloat
    let presentsPagesTree: Bool
    let isOffline: Bool
    @Binding var isPresentingShareSheet: Bool
    @Binding var isPresentingOptionsSheet: Bool
    @Binding var pendingShareAfterOptions: Bool
    @Binding var pendingOutlineAfterOptions: Bool
    @Binding var conflictToResolve: IdentifiedSyncConflict?
    @Binding var documentPendingMove: Document?
    @Binding var toastMessage: ToastMessage?
    let pagesDrawerPresentation: AnyViewModifier
    let shareSheet: () -> ShareSheet
    let optionsSheet: () -> OptionsSheet
    let presentOutlineAfterOptions: () -> Void
    let onKeepMine: () -> Void
    let onKeepServer: () -> Void

    init(
        client: DocsAPIClient,
        saveCoordinator: DocumentSaveCoordinator,
        signedInUser: SignedInUserStore,
        theme: AppTheme,
        toastBottomInset: CGFloat,
        presentsPagesTree: Bool,
        isOffline: Bool,
        isPresentingShareSheet: Binding<Bool>,
        isPresentingOptionsSheet: Binding<Bool>,
        pendingShareAfterOptions: Binding<Bool>,
        pendingOutlineAfterOptions: Binding<Bool>,
        conflictToResolve: Binding<IdentifiedSyncConflict?>,
        documentPendingMove: Binding<Document?>,
        toastMessage: Binding<ToastMessage?>,
        pagesDrawerPresentation: some ViewModifier,
        @ViewBuilder shareSheet: @escaping () -> ShareSheet,
        @ViewBuilder optionsSheet: @escaping () -> OptionsSheet,
        presentOutlineAfterOptions: @escaping () -> Void,
        onKeepMine: @escaping () -> Void,
        onKeepServer: @escaping () -> Void
    ) {
        self.client = client
        self.saveCoordinator = saveCoordinator
        self.signedInUser = signedInUser
        self.theme = theme
        self.toastBottomInset = toastBottomInset
        self.presentsPagesTree = presentsPagesTree
        self.isOffline = isOffline
        self._isPresentingShareSheet = isPresentingShareSheet
        self._isPresentingOptionsSheet = isPresentingOptionsSheet
        self._pendingShareAfterOptions = pendingShareAfterOptions
        self._pendingOutlineAfterOptions = pendingOutlineAfterOptions
        self._conflictToResolve = conflictToResolve
        self._documentPendingMove = documentPendingMove
        self._toastMessage = toastMessage
        self.pagesDrawerPresentation = AnyViewModifier(pagesDrawerPresentation)
        self.shareSheet = shareSheet
        self.optionsSheet = optionsSheet
        self.presentOutlineAfterOptions = presentOutlineAfterOptions
        self.onKeepMine = onKeepMine
        self.onKeepServer = onKeepServer
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $documentPendingMove) { document in
                MoveDocumentSheet(
                    client: client, document: document,
                    saveCoordinator: saveCoordinator, signedInUser: signedInUser
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .background(theme.colors.surfacePage)
            .toast($toastMessage, bottomInset: toastBottomInset)
            .accessibilityHidden(presentsPagesTree)
            .modifier(pagesDrawerPresentation)
            .sheet(isPresented: $isPresentingShareSheet) { shareSheet() }
            .sheet(
                isPresented: $isPresentingOptionsSheet,
                onDismiss: {
                    if pendingShareAfterOptions && !isOffline {
                        pendingShareAfterOptions = false
                        isPresentingShareSheet = true
                    } else if pendingOutlineAfterOptions {
                        pendingOutlineAfterOptions = false
                        presentOutlineAfterOptions()
                    }
                }
            ) {
                optionsSheet()
            }
            .sheet(item: $conflictToResolve) { conflict in
                ConflictSheetView(
                    conflict: conflict.value,
                    onKeepMine: onKeepMine,
                    onKeepServer: onKeepServer
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
    }
}

private struct AnyViewModifier: ViewModifier {
    private let build: (Content) -> AnyView

    init<M: ViewModifier>(_ modifier: M) {
        self.build = { content in AnyView(content.modifier(modifier)) }
    }

    func body(content: Content) -> some View {
        build(content)
    }
}

/// Classic Markdown/BlockNote reading & editing canvases hosted inside `EditorView`'s
/// unified shell when `NativeEditorOpen.route == .classic`.
private struct ClassicEditorView: View {
    @Environment(\.docsTheme) private var theme
    @Bindable var viewModel: EditorViewModel
    let reach: LinkReach
    let canUpdateLiveDocument: Bool
    let serverHost: String
    let serverOrigin: String
    let offlineOverride: Bool
    let canOpenDocuments: Bool
    private var isOffline: Bool { offlineOverride || viewModel.availability.isOffline }
    private var showsOfflineStatus: Bool { offlineOverride || viewModel.availability.showsOfflineStatus }

    @Binding var outlineScrollRequest: DocumentScrollRequest?
    @Binding var isPresentingOutline: Bool
    @Binding var outlineFocusesFind: Bool
    @Binding var outlineGate: OutlinePresentationGate
    @Binding var outlineHeldNavigation: OutlineHeldNavigation<EditorNavigation>
    let hasPendingPresentation: Bool
    let scrollAnchor: EditorScrollAnchorStore
    @Binding var readingPosition: ReadingPositionSession
    @Binding var subpageSwipe: SwipeRevealState<UUID>
    @Binding var documentPendingUndo: Document?
    @Binding var subpagePendingDeleteConfirmation: Document?
    @Binding var documentPendingMove: Document?
    let onNavigate: (EditorNavigation) -> Void
    let onPerformNavigation: (EditorNavigation) -> Void
    let onPresentOutline: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LocalizationStore.self) private var loc
    @Environment(DocumentCollaborationManager.self) private var collaboration: DocumentCollaborationManager?

    @State private var readingScrollPosition = ScrollPosition()
    @State private var restoreAnnouncementTask: Task<Void, Never>?
    @State private var restoreLayoutPass = 0
    @State private var checklistRevealFocusRequest = 0
    @State private var checklistSettleTasks: [UUID: Task<Void, Never>] = [:]
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var holdsCollaborationSession = false
    @State private var liveEditingBridge: LiveEditingBridge?

    var body: some View {
        Group {
            if viewModel.isLoading {
                EditorLoadingPlaceholder()
            } else if viewModel.needsOnlineContent {
                ContentUnavailableView {
                    Label {
                        Text(loc[.editor_offline_unavailable_title])
                    } icon: {
                        MaterialSymbol(.wifi_off, size: 44)
                    }
                } description: {
                    Text(loc[.editor_offline_open_online])
                } actions: {
                    if !viewModel.availability.isOffline {
                        DocsButton(title: loc[.common_retry], variant: .secondary) {
                            Task { await viewModel.reloadAfterReconnect() }
                        }
                    }
                }
            } else if viewModel.isEditing {
                editingSurface
            } else {
                readingSurface
            }
        }
        .modifier(outlinePresentation)
        .task(id: viewModel.availability.token) {
            if viewModel.availability.isOffline {
                viewModel.pauseLoadingWhileOffline()
                if !viewModel.hasLoadedContent { await viewModel.load() }
            } else {
                await viewModel.reloadAfterReconnect()
            }
        }
        .onAppear {
            requestCollaborationSessionIfNeeded()
        }
        .onChange(of: collaboration?.availability) { _, _ in
            requestCollaborationSessionIfNeeded()
        }
        .onChange(of: collaboration?.replicaVersion(for: viewModel.documentID)) { _, _ in
            liveEditingBridge?.replicaDidChange()
        }
        .onChange(of: collaboration?.initialSyncVersion(for: viewModel.documentID)) { _, _ in
            liveEditingBridge?.initialSyncDidChange()
        }
        .onChange(of: collaboration?.remoteChangeToken(for: viewModel.documentID)) { _, _ in
            if liveEditingBridge?.isApplyingLiveContent != true {
                viewModel.noteRemoteChange()
            }
        }
        .onDisappear {
            viewModel.flushPendingChanges()
            liveEditingBridge?.stopRemoteApplies()
            persistReadingPosition()
            readingPosition.dismissBackToTop()
            readingPosition.cancelPendingRestore()
            restoreAnnouncementTask?.cancel()
            restoreAnnouncementTask = nil
            for task in checklistSettleTasks.values { task.cancel() }
            checklistSettleTasks = [:]
            viewModel.clearChecklistSettling()
            if holdsCollaborationSession {
                collaboration?.release(viewModel.documentID)
                holdsCollaborationSession = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                viewModel.flushPendingChanges()
                persistReadingPosition()
            }
        }
    }

    private var outlinePresentation: DocumentOutlinePresentation {
        DocumentOutlinePresentation(
            isPresented: $isPresentingOutline, focusesFind: outlineFocusesFind,
            documentTitle: viewModel.title,
            blocks: viewModel.checklistReadingPresentation.rows.map(\.block),
            findShortcutTitle: loc[.outline_find_placeholder],
            findShortcutEnabled: viewModel.hasLoadedContent && !viewModel.isLoading && !hasPendingPresentation,
            closesOutline: outlineGate.closesOutline(hasPendingRequest: hasPendingPresentation),
            onFindShortcut: { onPresentOutline(true) },
            onScroll: { target in requestOutlineScroll(to: target) },
            onAppear: { outlineGate.outlineAppeared() },
            onDismiss: {
                outlineGate.outlineDismissed()
                if let held = outlineHeldNavigation.takeAfterOutlineDismissed() { onPerformNavigation(held) }
            },
            onSelectHeading: { blockID in
                if viewModel.isEditing { viewModel.focusedBlockID = blockID }
                requestOutlineScroll(to: .block(blockID))
            })
    }

    private func requestOutlineScroll(to target: EditorScrollTarget) {
        readingPosition.noteDeliberateJump(blocks: viewModel.blocks)
        outlineScrollRequest = DocumentScrollRequest.following(outlineScrollRequest, target: target)
    }

    private func heldForOutline(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { outlineGate.releases(binding.wrappedValue) }, set: { binding.wrappedValue = $0 })
    }

    private func heldForOutline<Item>(_ binding: Binding<Item?>) -> Binding<Item?> {
        Binding(get: { outlineGate.release(binding.wrappedValue) }, set: { binding.wrappedValue = $0 })
    }

    // MARK: - Editing

    private var editingSurface: some View {
        BlockEditorView(
            viewModel: viewModel, serverOrigin: serverOrigin, isOffline: isOffline, scrollAnchor: scrollAnchor,
            scrollRequest: outlineScrollRequest
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
                peers: headerPeers, onConsumeInitialTitleFocus: viewModel.consumeInitialTitleFocus
            ) {
                editingStatus
            }
        }
        .safeAreaInset(edge: .bottom) {
            // A container so the glass surfaces stacked here (the bar, and the
            // slash menu or `[[` page picker when one is up) are rendered as one
            // system pass and blend where they meet, rather than as separate
            // panes sitting on top of each other.
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
                    // "Link a page", opened by typing `[[`. Never up together with the
                    // slash menu: `pageLinkPicker` is nil while a slash query is open.
                    PageLinkPickerHost(viewModel: viewModel)
                    EditorFormattingBar(viewModel: viewModel, isOffline: isOffline)
                }
            }
            .padding(.horizontal, DocsSpacing.gutter)
            .padding(.bottom, DocsSpacing.spaceXS)
        }
        // The out-of-process system picker: no photo-library usage description and
        // no project.yml change are needed. Do NOT add `photoLibrary: .shared()` —
        // that makes it in-process and would require NSPhotoLibraryUsageDescription.
        .photosPicker(
            isPresented: heldForOutline($viewModel.isPhotoPickerPresented), selection: $selectedPhotoItem,
            matching: .images
        )
        // The system document picker, also out of process: no usage description
        // and no project.yml change. `.item` because the server decides what it
        // will accept — the app has no business second-guessing which types a
        // deployment allows.
        .fileImporter(
            isPresented: heldForOutline($viewModel.isAttachmentImporterPresented),
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
        .sheet(item: heldForOutline($viewModel.linkEditor)) { request in
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
            hasUnsavedLocalContent: viewModel.hasUnsavedLocalContent,
            connectionDown: offlineOverride || viewModel.availability.connectionAppearsDown)
        if display == .none {
            syncCaptionLabel
        } else {
            SaveStatusIndicator(
                display: display, failureDetail: viewModel.saveFailureDetail,
                failureOffersRetry: viewModel.saveFailureOffersRetry, onTap: { viewModel.saveNow() })
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
                .foregroundStyle(theme.colors.textSecondary)
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
    /// editing canvas moves nothing.
    ///
    /// A flat stack rather than nested section stacks: the two canvases have to
    /// contribute the same gaps in the same order for the scroll offset to mean
    /// the same thing in both.
    private var readingSurface: some View {
        let presentation = viewModel.checklistReadingPresentation
        let numbering = numberedIndices(in: viewModel.blocks)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: EditorBlockMetrics.blockSpacing) {
                    readingHeader
                        // Tops the stack's own `blockSpacing` up to the header-to-body
                        // gap, exactly as the editing canvas does.
                        .padding(.bottom, EditorBlockMetrics.headerToBodySpacing - EditorBlockMetrics.blockSpacing)

                    if presentation.hasChecklistItems {
                        ChecklistReadingControls(
                            hidesCompleted: Binding(
                                get: { viewModel.hidesCompletedChecklistItems },
                                set: { viewModel.setHidesCompletedChecklistItems($0) }),
                            hiddenCount: presentation.hiddenCount,
                            revealFocusRequest: checklistRevealFocusRequest)
                    }

                    if viewModel.blocks.isEmpty {
                        // `isDocumentPendingDelete` joins the error check for the same reason the
                        // error is here at all: the gated load leaves `blocks` empty *and* — since the
                        // notice is rendered from the predicate rather than an `errorKey` — no error to
                        // suppress this. Without it the screen claims a document with content is empty
                        // and offers "Start writing", which `canStartEditing` makes a silent no-op.
                        if viewModel.hasLoadedContent, viewModel.errorKey == nil, !viewModel.isDocumentPendingDelete {
                            emptyContent
                        }
                    } else {
                        ForEach(presentation.rows) { row in
                            let index = row.sourceIndex
                            let block = row.block
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
                                        onRemove: { viewModel.removePendingAttachment(blockID: block.id) }
                                    )
                                    // Inset by its nesting, as `MarkdownBlockView`'s image arm is.
                                    .padding(.leading, EditorBlockMetrics.listIndentInset(block.indent))
                                } else if case .checklistItem = block.kind {
                                    MarkdownBlockView(
                                        block: block, serverOrigin: serverOrigin,
                                        numberedIndex: numbering[index],
                                        isOffline: isOffline,
                                        onToggleChecklist: { toggleChecklistFromReading(block.id) },
                                        onTapText: {
                                            snapshotScrollForModeSwap()
                                            viewModel.startEditing(focusing: block.id)
                                        }
                                    )
                                } else {
                                    MarkdownBlockView(
                                        block: block, serverOrigin: serverOrigin,
                                        numberedIndex: numbering[index],
                                        isOffline: isOffline
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        // Snapshot before the swap, not during it:
                                        // the outgoing ScrollView's last geometry
                                        // report is zero.
                                        snapshotScrollForModeSwap()
                                        viewModel.startEditing(focusing: block.id)
                                    }
                                }
                            }
                            .id(EditorScrollTarget.block(block.id))
                            .recordingEditorBlockFrame(block.id)
                            // Plays only inside a settled tick's collapse (`toggleChecklistFromReading`);
                            // everywhere else a row appearing or going (a remote edit, the Hide
                            // completed switch) is unchanged.
                            .transition(DocsMotion.checklistCollapseTransition(reduceMotion: reduceMotion))
                        }
                    }

                    subpagesSection
                        .padding(.top, EditorBlockMetrics.headerToBodySpacing - EditorBlockMetrics.blockSpacing)
                }
                .padding(.horizontal, EditorBlockMetrics.gutter)
                .padding(.top, DocsSpacing.spaceSM)
                .padding(.bottom, DocsSpacing.spaceLG)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollPosition($readingScrollPosition)
            // Recorded continuously, read once — when the editing canvas appears
            // and asks where the reader was.
            //
            // The `+ contentInsets.top` normalizes to "distance scrolled from the
            // content's own top edge", which is the origin `scrollTo(y:)` uses,
            // whereas `contentOffset.y` is measured from the scroll view's bounds.
            // **Measured as zero for these two scroll views**, so it changes nothing
            // today and is kept only because the un-normalized form is wrong the
            // moment either surface gains a top inset. It is *not* what fixed the
            // ~110pt error the handoff first showed — that was the editing canvas's
            // `LazyVStack` clamping the restore, and adding this term made no
            // difference to it whatsoever.
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentOffset.y + $0.contentInsets.top
            } action: { _, offset in
                scrollAnchor.noteScrolled(to: offset)
            }
            .onPreferenceChange(EditorBlockFramesKey.self) { frames in
                scrollAnchor.noteBlockFrames(frames)
                if readingPosition.hasPendingRestoreScroll { restoreLayoutPass &+= 1 }
            }
            .onAppear {
                if let blockID = scrollAnchor.consumePendingBlock() {
                    if presentation.rows.contains(where: { $0.id == blockID }) {
                        proxy.scrollTo(EditorScrollTarget.block(blockID), anchor: .top)
                    } else {
                        readingScrollPosition.scrollTo(y: 0)
                    }
                } else if let offsetY = scrollAnchor.consumePendingOffset() {
                    readingScrollPosition.scrollTo(y: offsetY)
                } else {
                    restoreReadingPosition(proxy)
                }
            }
            // Content that arrives after the surface appeared. This is the **cached** open, not
            // the rare one: `load()` installs the cached body from `.task`, after this surface
            // has appeared over an empty page (only a network fetch shows the loading
            // placeholder, and so brings a new surface that restores from `onAppear`).
            .onChange(of: viewModel.hasLoadedContent) { _, _ in restoreReadingPosition(proxy) }
            // The rows that content inserted have now been laid out; scroll to the decided block.
            .onChange(of: restoreLayoutPass) { _, _ in scrollToPendingRestore(proxy) }
            // Flipping "Hide completed" changes which rows exist; a restore still pending was
            // decided against the old set and must not land on the new one later.
            .onChange(of: viewModel.hidesCompletedChecklistItems) { _, _ in
                readingPosition.cancelPendingRestore()
            }
            .onChange(of: outlineScrollRequest) { _, request in
                guard let request else { return }
                // The reading header carries no scroll id; the top is offset zero.
                if request.target == .header {
                    readingScrollPosition.scrollTo(y: 0)
                } else {
                    proxy.scrollTo(request.target, anchor: .top)
                }
            }
            .refreshable {
                await viewModel.refresh()
            }
            // The Subpages rows live in this scroll view, so an open swipe strip closes here for
            // the same reason it does on Home and in the drawer — and guarded the same way, so a
            // swipe that nudges this scroll view does not close its own strip.
            .onScrollPhaseChange { _, phase in
                // Any movement ends the offer, including the programmatic and VoiceOver scrolls
                // that never report `.interacting`.
                if phase != .idle { readingPosition.dismissBackToTop() }
                if phase == .interacting {
                    // The reader took hold of the page before a restore landed; leave it with them.
                    readingPosition.cancelPendingRestore()
                    subpageSwipe = swipeRevealAfterScrollInteraction(subpageSwipe)
                }
            }
            // A `.link` run in a `Text` — an inline markdown link, or a bare URL the
            // autolinker matched — dispatches through this action. Without an override the
            // default one hands every link to the system, so a link to a sub-page left the app
            // for Safari. Scoped to the reading surface: it is the only subtree that renders
            // content the user didn't type, and the sheets keep the system behavior.
            .environment(\.openURL, OpenURLAction(handler: openLink))
            .overlay(alignment: .bottom) { backToTopOffer }
            // Keeps "Back to top" reachable from the VoiceOver actions rotor on the reading surface.
            .accessibilityActions {
                if readingPosition.offersBackToTop {
                    Button(loc[.editor_back_to_top]) { backToTop() }
                }
            }
        }
    }

    // MARK: - Continue reading

    /// Decides the restore once the content is here, and scrolls at once if its rows are already
    /// laid out (the surface appeared with its content). Otherwise — content that has only just
    /// been inserted, as a cached open's is — the next layout's frames report runs the scroll
    /// (`restoreLayoutPass`).
    private func restoreReadingPosition(_ proxy: ScrollViewProxy) {
        guard
            readingPosition.beginRestore(
                blocks: viewModel.blocks, userHasScrolled: scrollAnchor.currentOffsetY > 8) != nil
        else { return }
        scrollToPendingRestore(proxy)
    }

    /// Scrolls to the block the reader left off at, once its row is laid out. Not animated:
    /// it is the page opening, not a gesture, and it must not fight the layout still settling.
    private func scrollToPendingRestore(_ proxy: ScrollViewProxy) {
        guard
            let blockID = readingPosition.takeRestoreScroll(
                presentedBlockIDs: Set(viewModel.checklistReadingPresentation.rows.map(\.id)),
                laidOutBlockIDs: scrollAnchor.laidOutBlockIDs, voiceOverEnabled: voiceOverEnabled)
        else { return }
        proxy.scrollTo(EditorScrollTarget.block(blockID), anchor: .top)
        // The jump is silent for VoiceOver users otherwise, like the Toast announcement.
        // Posted after the push transition settles, otherwise the screen change speech cuts it off.
        let message = loc[.editor_continued_reading]
        restoreAnnouncementTask?.cancel()
        restoreAnnouncementTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            AccessibilityNotification.Announcement(message).post()
        }
    }

    private func backToTop() {
        readingPosition.dismissBackToTop()
        if reduceMotion {
            readingScrollPosition.scrollTo(y: 0)
        } else {
            withAnimation(.snappy) { readingScrollPosition.scrollTo(y: 0) }
        }
    }

    private func persistReadingPosition() {
        readingPosition.persist(blocks: viewModel.blocks, topVisibleBlockID: scrollAnchor.lastTopVisibleBlockID)
    }

    /// Respects Reduce Motion: the pill appears and goes without animating, and the scroll back
    /// is instant.
    private var backToTopOffer: some View {
        ZStack {
            if readingPosition.offersBackToTop {
                BackToTopPill(title: loc[.editor_back_to_top], accessibilityLabel: loc[.editor_back_to_top_a11y]) {
                    backToTop()
                }
                .padding(.bottom, DocsSpacing.spaceBase)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: readingPosition.offersBackToTop)
    }

    /// A checkbox tapped on the reading surface.
    ///
    /// With completed items hidden, a tick is two phases, so the row is seen ticked before it
    /// goes: first the tick alone (the row stays, checked, while its checkbox pulses), then —
    /// after `DocsMotion.checklistSettleDelay` — the row leaves inside the collapse animation
    /// (a fade under Reduce Motion, after a shorter beat) and the rows below close up. An
    /// untick during the beat cancels the second phase and the row stays.
    private func toggleChecklistFromReading(_ blockID: UUID) {
        guard viewModel.hidesCompletedChecklistItems else {
            viewModel.toggleChecklist(blockID: blockID)
            return
        }
        checklistSettleTasks[blockID]?.cancel()
        checklistSettleTasks[blockID] = nil
        guard let token = viewModel.toggleChecklistSettling(blockID: blockID) else { return }
        let delay = DocsMotion.checklistSettleDelay(reduceMotion: reduceMotion)
        let collapse = DocsMotion.checklistCollapseAnimation(reduceMotion: reduceMotion)
        checklistSettleTasks[blockID] = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            checklistSettleTasks[blockID] = nil
            let hid = withAnimation(collapse) {
                viewModel.finishChecklistSettling(blockID: blockID, token: token)
            }
            // The row may have held VoiceOver focus; give it the reveal control to land on.
            if hid { checklistRevealFocusRequest += 1 }
        }
    }

    /// Raw offsets still preserve the ordinary parity handoff. With checklist
    /// chrome or hidden rows, measured block identity preserves the logical place.
    private func snapshotScrollForModeSwap() {
        // The reading surface is about to be replaced; the offer and a restore not yet
        // scrolled to belong to it.
        readingPosition.dismissBackToTop()
        readingPosition.cancelPendingRestore()
        guard viewModel.checklistReadingPresentation.hasChecklistItems || viewModel.hidesCompletedChecklistItems else {
            scrollAnchor.snapshotForSwap()
            return
        }
        let allIDs = viewModel.blocks.map(\.id)
        let readingIDs = ChecklistReadingPresentation(
            blocks: viewModel.blocks, hidingCompleted: viewModel.hidesCompletedChecklistItems,
            settling: viewModel.checklistSettling.ids
        ).rows.map(\.id)
        scrollAnchor.snapshotForSwap(
            blockOrder: viewModel.isEditing ? allIDs : readingIDs,
            restoringAmong: viewModel.isEditing ? readingIDs : allIDs)
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
            guard onOpenDocument != nil else { return .systemAction }
            Task {
                if let document = await viewModel.openLinkedDocument(linkedID) {
                    navigate(.open(document))
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
            .foregroundStyle(theme.colors.textBrand)
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
        if collaboration.session(for: viewModel.documentID, canUpdate: canUpdateLiveDocument) != nil {
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
        let open: () -> Void = {
            if isPendingDelete {
                documentPendingUndo = child
            } else {
                navigate(.open(child))
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
                .fill(theme.colors.borderDefault)
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
                .foregroundStyle(theme.colors.textTertiary)
                .padding(.horizontal, DocsSpacing.spaceXS)
                // The eyebrow hugs the first row (reference 4pt), not a 12pt gap.
                .padding(.bottom, DocsSpacing.space3xs)

                if let subpages = viewModel.mergedSubpages {
                    if subpages.isEmpty {
                        Text(loc[.editor_subpages_empty])
                            .font(DocsFont.footnote)
                            .foregroundStyle(theme.colors.textTertiary)
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
                            navigate(.created(child))
                        }
                    }
                } label: {
                    HStack(spacing: DocsSpacing.spaceXS) {
                        MaterialSymbol(.add, size: 22)
                        Text(loc[.editor_add_subpage])
                            .docsScaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                    }
                    .foregroundStyle(theme.colors.textBrand)
                    .padding(.horizontal, DocsSpacing.spaceXS)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isAddingSubpage)
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
            isOffline: showsOfflineStatus,
            controlsOffline: isOffline,
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

    /// Template images let the native toolbar recognize icon-only actions and
    /// keep their glass surfaces circular. Each button states its own label: the glyph is a
    /// Private-Use-Area character with no spoken text.
    @ViewBuilder
    private func toolbarButton(for action: EditorToolbarAction) -> some View {
        switch action {
        case .edit:
            Button {
                snapshotScrollForModeSwap()
                viewModel.startEditing()
            } label: {
                ToolbarIcon(.edit)
            }
            // `startEditing` silently declines without loaded content, and offline with
            // nothing cached that is now the common case — where the load error also
            // suppresses "Start writing", leaving Edit as the only affordance on screen
            // doing nothing at all. Mirror the formatting bar's rule: if the view model
            // would decline, don't invite the tap. `canStartEditing` is the very predicate
            // the guard uses, so the two cannot drift; it is keyed to loaded content, not
            // to connectivity — the parameter this resolver dropped.
            .disabled(!viewModel.canStartEditing)
            .buttonBorderShape(.circle)
            .accessibilityLabel(loc[.editor_action_edit])

        case .done:
            Button {
                snapshotScrollForModeSwap()
                viewModel.finishEditing()
            } label: {
                ToolbarIcon(.check, filled: true)
            }
            .buttonBorderShape(.circle)
            .accessibilityLabel(loc[.editor_action_done])

        case .share:
            Button {
                guard !isOffline else { return }
                isPresentingShareSheet = true
            } label: {
                ToolbarIcon(.share)
            }
            .buttonBorderShape(.circle)
            .accessibilityLabel(loc[.editor_action_share])

        case .options:
            Button {
                isPresentingOptionsSheet = true
            } label: {
                ToolbarIcon(.more_horiz)
            }
            .buttonBorderShape(.circle)
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
    .environment(ImageLoader.inert())
}

/// Shared label geometry for the editor's actionable conflict and update notices.
struct EditorNoticeLabel: View {
    @Environment(\.docsTheme) private var theme
    let icon: MaterialIcon
    let title: String
    let foreground: Color

    var body: some View {
        HStack(spacing: DocsSpacing.space2xs) {
            MaterialSymbol(icon, size: 13)
            Text(title).font(DocsFont.footnote)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, DocsSpacing.spaceSM)
        .padding(.vertical, DocsSpacing.space2xs)
        .frame(minHeight: DocsSpacing.rowMinHeight)
        .background(Capsule().fill(theme.colors.gray050))
        .contentShape(Capsule())
    }
}

// MARK: - Loading

/// The editor's first-load state: placeholder bars where the document header and its first
/// lines will appear, on an otherwise empty page.
///
/// A skeleton rather than a spinner, per the handoff's loading rule, laid out on the reading
/// surface's own gutter and header spacing so the title lands where its bar was. A document
/// opened with an unconsumed creation intent never shows it: it opens straight into editing
/// (`EditorViewModel.seedNewlyCreatedDocument`), since its body is empty by construction.
///
/// It **fills what it is offered** rather than sizing to its content, because the page
/// background is painted behind the column it sits in: sized to a spinner, that column was
/// a spinner wide, and a Paper (or any non-white) theme showed its colour only as a strip
/// down the middle of the screen. `EditorLoadingPlaceholderTests` measures it against a
/// full-screen proposal.
struct EditorLoadingPlaceholder: View {
    @Environment(LocalizationStore.self) private var loc

    /// Fixed rhythm, like `SkeletonList`'s, so the placeholder doesn't reshuffle on redraw.
    static let bodyLineFractions: [CGFloat] = [1, 0.92, 0.97, 0.6]

    var body: some View {
        VStack(alignment: .leading, spacing: EditorBlockMetrics.blockSpacing) {
            VStack(alignment: .leading, spacing: EditorBlockMetrics.titleToMetadataSpacing) {
                SkeletonLine(fraction: 0.62, height: 28)
                HStack(spacing: DocsSpacing.spaceXS) {
                    Skeleton(width: 76, height: 20, cornerRadius: DocsRadius.pill)
                    Skeleton(width: 92, height: 11)
                }
                .frame(minHeight: DocsSpacing.rowMinHeight, alignment: .leading)
            }
            .padding(.bottom, EditorBlockMetrics.headerToBodySpacing - EditorBlockMetrics.blockSpacing)

            ForEach(Array(Self.bodyLineFractions.enumerated()), id: \.offset) { _, fraction in
                SkeletonLine(fraction: fraction, height: 13)
            }
        }
        .padding(.horizontal, EditorBlockMetrics.gutter)
        .padding(.top, DocsSpacing.spaceSM)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc[.common_loading])
    }
}

/// One placeholder text line, a fraction of the column wide.
private struct SkeletonLine: View {
    let fraction: CGFloat
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Skeleton(width: proxy.size.width * fraction, height: height)
        }
        .frame(height: height)
    }
}

#Preview("Loading placeholder") {
    EditorLoadingPlaceholder()
        .environment(LocalizationStore())
}

#Preview("Loading placeholder, dark") {
    EditorLoadingPlaceholder()
        .environment(LocalizationStore())
        .preferredColorScheme(.dark)
}
