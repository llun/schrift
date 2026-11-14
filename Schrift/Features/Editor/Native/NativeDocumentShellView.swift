import SwiftUI

/// Shared banner stack above the document surface across classic and native routes.
struct EditorBannerStack: View {
    @Environment(\.docsTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(LocalizationStore.self) private var loc

    let showsOfflineBanner: Bool
    let hasLocalCopy: Bool
    let hasConflict: Bool
    let showUpdateAvailable: Bool
    let isDocumentPendingDelete: Bool
    let errorKey: L10nKey?
    let errorDetail: String?
    let onTapConflict: () -> Void
    let onApplyPendingUpdate: () -> Void
    let onUndoPendingDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if showsOfflineBanner, hasLocalCopy {
                OfflineBanner(note: loc[.editor_offline_local_copy])
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if hasConflict {
                Button(action: onTapConflict) {
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

            if showUpdateAvailable {
                Button(action: onApplyPendingUpdate) {
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

            if isDocumentPendingDelete {
                VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
                    Text(loc[.editor_pending_delete])
                        .font(DocsFont.footnote)
                        .foregroundStyle(theme.colors.textSecondary)
                    DocsButton(title: loc[.pending_delete_undo], variant: .secondary, size: .medium) {
                        onUndoPendingDelete()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.top, DocsSpacing.spaceXS)
            } else if let errorKey {
                VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
                    Text(loc[errorKey])
                        .font(DocsFont.footnote)
                        .foregroundStyle(theme.colors.danger)
                    if let errorDetail {
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
        .animation(reduceMotion ? nil : .snappy, value: hasConflict)
        .animation(reduceMotion ? nil : .snappy, value: showUpdateAvailable)
        .animation(reduceMotion ? nil : .snappy, value: errorKey)
    }
}

/// Shared periodic "Synced X ago" / retry caption slot for `EditorDocumentHeader`.
struct EditorSyncCaptionLabel: View {
    @Environment(LocalizationStore.self) private var loc

    let hasUnsavedLocalContent: Bool
    let hasConflict: Bool
    let showsOfflineStatus: Bool
    let controlsOffline: Bool
    let saveState: EditorViewModel.SaveState
    let lastSyncedAt: Date?
    let onRetry: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let caption = syncCaption(
                hasUnsavedLocalContent: hasUnsavedLocalContent,
                hasConflict: hasConflict,
                isOffline: showsOfflineStatus,
                controlsOffline: controlsOffline,
                saveState: saveState,
                lastSyncedAt: lastSyncedAt,
                now: context.date,
                locale: loc.locale)
            let resolved = resolvedCaption(caption.text)
            SyncCaptionLabel(
                offersRetry: caption.offersRetry,
                text: resolved,
                retryAccessibilityLabel: caption.text == .key(.editor_sync_save_failed)
                    ? loc[.editor_sync_save_failed_a11y] : resolved,
                onRetry: onRetry)
        }
    }

    private func resolvedCaption(_ text: SyncCaptionText) -> String {
        switch text {
        case .key(let key): return loc[key]
        case .syncedAgo(let ago): return loc.format(.editor_sync_ago, ago)
        }
    }
}

/// Shared subpages list + "Add a page" section below a document body.
struct EditorSubpagesSection: View {
    @Environment(\.docsTheme) private var theme
    @Environment(LocalizationStore.self) private var loc

    let viewModel: EditorViewModel
    @Binding var subpageSwipe: SwipeRevealState<UUID>
    @Binding var documentPendingUndo: Document?
    @Binding var subpagePendingDeleteConfirmation: Document?
    @Binding var documentPendingMove: Document?
    let onNavigate: (EditorNavigation) -> Void

    var body: some View {
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

                Button {
                    Task {
                        if let child = await viewModel.addSubpage() {
                            onNavigate(.created(child))
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
        .padding(.top, DocsSpacing.spaceXL - DocsSpacing.spaceMD)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func subpageRow(_ child: Document) -> some View {
        let isPendingDelete = viewModel.isDeletePending(child)
        let trimmed = child.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let childTitle = trimmed.isEmpty ? loc[.common_untitled] : trimmed
        let open: () -> Void = {
            if isPendingDelete {
                documentPendingUndo = child
            } else {
                onNavigate(.open(child))
            }
        }

        return SwipeRevealRow(
            id: child.id,
            state: $subpageSwipe,
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
}

/// Hosts the unified document shell (toolbar, banners, conflict resolution, Pages drawer,
/// Options, Share, header, and subpages) around the `.loading`, `.native`, and
/// `.preservedUnavailable` routes.
struct NativeDocumentShellView: View {
    @Environment(\.docsTheme) private var theme
    @Environment(LocalizationStore.self) private var loc

    let route: NativeEditorOpen.Route
    let nativeOpen: NativeEditorOpen
    let viewModel: EditorViewModel
    let reach: LinkReach
    let serverHost: String
    let serverOrigin: String
    let linkRole: LinkRole?
    let pinRow: Document?
    let offlineOverride: Bool
    let onDeleted: (() -> Void)?
    let onOpenDocument: ((Document) -> Void)?
    let onCreatedDocument: ((Document) -> Void)?
    let makeInlinePickerSource: () -> NativeInlinePickerSource
    let onReopenAfterUndo: () async -> Void

    @State private var offlineBannerStatus = DebouncedStatus()
    @State private var isPresentingShareSheet = false
    @State private var isPresentingOptionsSheet = false
    @State private var isPresentingOutline = false
    @State private var pendingOutlineAfterOptions = false
    @State private var pendingShareAfterOptions = false
    @State private var outlineGate = OutlinePresentationGate()
    @State private var outlineHeldNavigation = OutlineHeldNavigation<EditorNavigation>()
    @State private var outlineFocusesFind = false
    @State private var conflictToResolve: IdentifiedSyncConflict?
    @State private var toastMessage: ToastMessage?
    @State private var isPresentingPagesTree = false
    @State private var documentPendingUndo: Document?
    @State private var subpagePendingDeleteConfirmation: Document?
    @State private var drawerPendingDeleteConfirmation: Document?
    @State private var documentPendingMove: Document?
    @State private var subpageSwipe = SwipeRevealState<UUID>()
    @State private var pagesTreeViewModel: PagesTreeViewModel
    @State private var optionsViewModel: OptionsViewModel
    @State private var shareViewModel: ShareViewModel
    @State private var isNativeEditing = false

    private var editingToastInset: CGFloat { DocsSpacing.rowMinHeight + DocsSpacing.spaceBase }
    private var isOffline: Bool { offlineOverride || viewModel.availability.isOffline }
    private var showsOfflineStatus: Bool { offlineOverride || viewModel.availability.showsOfflineStatus }
    private var showsOfflineBanner: Bool {
        offlineOverride || viewModel.availability.isWorkOffline || offlineBannerStatus.value
    }

    private var canEditNative: Bool {
        if case .native(let session) = route {
            return session.input != nil && session.state.writable
        }
        return false
    }

    private var effectiveNativeEditing: Bool {
        isNativeEditing && canEditNative
    }

    private var nativeSessionIdentity: ObjectIdentifier? {
        if case .native(let session) = route {
            return ObjectIdentifier(session)
        }
        return nil
    }

    private var toastBottomInset: CGFloat {
        effectiveNativeEditing ? editingToastInset : 0
    }

    private var canOpenOutline: Bool {
        if case .native(let session) = route {
            return !session.hasUnsupportedRoot
        }
        return false
    }

    init(
        route: NativeEditorOpen.Route,
        nativeOpen: NativeEditorOpen,
        viewModel: EditorViewModel,
        reach: LinkReach,
        serverHost: String,
        serverOrigin: String,
        childrenCache: DocumentChildrenCacheStore,
        linkRole: LinkRole?,
        initialIsFavorite: Bool,
        pinRow: Document?,
        isOffline: Bool,
        onDeleted: (() -> Void)?,
        onOpenDocument: ((Document) -> Void)?,
        onCreatedDocument: ((Document) -> Void)?,
        makeInlinePickerSource: @escaping () -> NativeInlinePickerSource,
        onReopenAfterUndo: @escaping () async -> Void
    ) {
        self.route = route
        self.nativeOpen = nativeOpen
        self.viewModel = viewModel
        self.reach = reach
        self.serverHost = serverHost
        self.serverOrigin = serverOrigin
        self.linkRole = linkRole
        self.pinRow = pinRow
        self.offlineOverride = isOffline
        self.onDeleted = onDeleted
        self.onOpenDocument = onOpenDocument
        self.onCreatedDocument = onCreatedDocument
        self.makeInlinePickerSource = makeInlinePickerSource
        self.onReopenAfterUndo = onReopenAfterUndo
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
        mainContent
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
            .sheet(item: heldForOutline($documentPendingMove)) { document in
                MoveDocumentSheet(
                    client: viewModel.client, document: document,
                    saveCoordinator: viewModel.saveCoordinator, signedInUser: viewModel.signedInUser
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .background(theme.colors.surfacePage)
            .toast($toastMessage, bottomInset: toastBottomInset)
            .accessibilityHidden(presentsPagesTree)
            .modifier(pagesDrawerPresentation)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { shellToolbar }
            .onAppear {
                viewModel.noteEditorAppeared()
            }
            .onChange(of: viewModel.availability.token) { _, _ in
                if viewModel.availability.isOffline {
                    isPresentingShareSheet = false
                    pendingShareAfterOptions = false
                }
            }
            .onChange(of: isOffline) { _, offline in
                if offline {
                    isPresentingShareSheet = false
                    pendingShareAfterOptions = false
                }
            }
            .sheet(isPresented: heldForOutline($isPresentingShareSheet)) { shareSheet }
            .sheet(
                isPresented: heldForOutline($isPresentingOptionsSheet),
                onDismiss: {
                    if pendingShareAfterOptions && !isOffline {
                        pendingShareAfterOptions = false
                        isPresentingShareSheet = true
                    } else if pendingOutlineAfterOptions {
                        pendingOutlineAfterOptions = false
                        presentOutline(focusingFind: false)
                    }
                }
            ) {
                optionsSheet
            }
            .sheet(item: heldForOutline($conflictToResolve)) { conflict in
                ConflictSheetView(
                    conflict: conflict.value,
                    onKeepMine: { nativeOpen.resolveConflictKeepingMine(viewModel: viewModel) },
                    onKeepServer: {
                        Task {
                            await nativeOpen.resolveConflictKeepingServer(
                                viewModel: viewModel,
                                isOffline: isOffline,
                                canUpdate: pinRow?.abilities.update == true,
                                canMention: pinRow?.abilities.mention == true)
                        }
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            EditorBannerStack(
                showsOfflineBanner: showsOfflineBanner,
                hasLocalCopy: viewModel.hasLocalCopy,
                hasConflict: viewModel.syncConflict != nil,
                showUpdateAvailable: false,
                isDocumentPendingDelete: viewModel.isDocumentPendingDelete,
                errorKey: viewModel.errorKey,
                errorDetail: viewModel.errorDetail,
                onTapConflict: {
                    dismissFocusForConflictSheet()
                    conflictToResolve = viewModel.syncConflict.map(IdentifiedSyncConflict.init)
                },
                onApplyPendingUpdate: {},
                onUndoPendingDelete: {
                    viewModel.undoPendingDeleteForThisDocument()
                    Task { await onReopenAfterUndo() }
                }
            )

            switch route {
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
                    onSave: { nativeOpen.saveNow(viewModel: viewModel) }, isOffline: isOffline,
                    documentID: viewModel.documentID,
                    uploadDocumentID: viewModel.isLocalDocument ? nil : viewModel.documentID,
                    mediaQueue: viewModel.saveCoordinator,
                    documentTitle: { [viewModel] id in viewModel.cachedDocumentTitle(for: id) },
                    resolveLinkedDocument: { [viewModel] id in await viewModel.openLinkedDocument(id) },
                    onOpenDocument: { navigate(.open($0)) },
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
                    onScrollInteraction: { subpageSwipe = swipeRevealAfterScrollInteraction(subpageSwipe) }
                )
            case .preservedUnavailable:
                preservedUnavailableContent
            case .classic:
                EmptyView()
            }
        }
        .onChange(of: viewModel.availability.transportOfflineEvidence, initial: true) { _, raw in
            offlineBannerStatus.update(raw)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var preservedUnavailableContent: some View {
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

                subpagesSection
                    .padding(.top, EditorBlockMetrics.headerToBodySpacing - EditorBlockMetrics.blockSpacing)
            }
            .padding(.horizontal, EditorBlockMetrics.gutter)
            .padding(.top, DocsSpacing.spaceSM)
            .padding(.bottom, DocsSpacing.spaceLG)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting {
                subpageSwipe = swipeRevealAfterScrollInteraction(subpageSwipe)
            }
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
        subpagesSection
            .padding(.horizontal, EditorBlockMetrics.gutter)
            .padding(.bottom, DocsSpacing.spaceLG)
    }

    private var subpagesSection: some View {
        EditorSubpagesSection(
            viewModel: viewModel,
            subpageSwipe: $subpageSwipe,
            documentPendingUndo: $documentPendingUndo,
            subpagePendingDeleteConfirmation: $subpagePendingDeleteConfirmation,
            documentPendingMove: $documentPendingMove,
            onNavigate: navigate)
    }

    @ViewBuilder
    private func nativeHeaderStatus(session: NativeEditorSession?) -> some View {
        let hasUnsaved = viewModel.isNativeLocalContentUnsaved(
            sessionHasPendingSave: session?.hasPendingSave ?? false)
        if let session, session.input != nil {
            let display = nativeSaveStatus(session)
            if display == .none {
                EditorSyncCaptionLabel(
                    hasUnsavedLocalContent: hasUnsaved,
                    hasConflict: viewModel.syncConflict != nil,
                    showsOfflineStatus: showsOfflineStatus,
                    controlsOffline: isOffline,
                    saveState: viewModel.saveState,
                    lastSyncedAt: viewModel.lastSyncedAt,
                    onRetry: { nativeOpen.saveNow(viewModel: viewModel) })
            } else {
                SaveStatusIndicator(
                    display: display, failureDetail: viewModel.saveFailureDetail,
                    failureOffersRetry: viewModel.saveFailureOffersRetry,
                    onTap: { nativeOpen.saveNow(viewModel: viewModel) })
            }
        } else {
            EditorSyncCaptionLabel(
                hasUnsavedLocalContent: hasUnsaved,
                hasConflict: viewModel.syncConflict != nil,
                showsOfflineStatus: showsOfflineStatus,
                controlsOffline: isOffline,
                saveState: viewModel.saveState,
                lastSyncedAt: viewModel.lastSyncedAt,
                onRetry: { nativeOpen.saveNow(viewModel: viewModel) })
        }
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
            Button {
            } label: {
                ToolbarIcon(.edit)
            }
            // Reading <-> Editing mode handoff lands in Step 2 (G04).
            .disabled(true)
            .buttonBorderShape(.circle)
            .accessibilityLabel(loc[.editor_action_edit])
            .accessibilityHidden(presentsPagesTree)
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        if editorToolbarActions(
            isEditing: false, isLocal: viewModel.isLocalDocument, isOffline: isOffline
        ).contains(.share) {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard !isOffline else { return }
                    isPresentingShareSheet = true
                } label: {
                    ToolbarIcon(.share)
                }
                .buttonBorderShape(.circle)
                .accessibilityLabel(loc[.editor_action_share])
                .accessibilityHidden(presentsPagesTree)
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isPresentingOptionsSheet = true
            } label: {
                ToolbarIcon(.more_horiz)
            }
            .buttonBorderShape(.circle)
            .accessibilityLabel(loc[.editor_action_options])
            .accessibilityHidden(presentsPagesTree)
        }
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
            onOutline: canOpenOutline ? { pendingOutlineAfterOptions = true } : nil,
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

    private func dismissFocusForConflictSheet() {
        viewModel.dismissFocusForSheet()
        if case .native(let session) = route {
            session.textView.resignFirstResponder()
        }
    }

    private func nativeSaveStatus(_ session: NativeEditorSession) -> SaveStatusDisplay {
        if session.hasPendingSave || viewModel.hasPendingNativeTitleEdit { return .savedOnDevice }
        let hasConflict = viewModel.syncConflict != nil
        return saveStatusDisplay(
            saveState: viewModel.saveState, hasConflict: hasConflict,
            hasUnsavedLocalContent: viewModel.isNativeLocalContentUnsaved(
                sessionHasPendingSave: session.hasPendingSave),
            connectionDown: isOffline || viewModel.availability.connectionAppearsDown)
    }
}
