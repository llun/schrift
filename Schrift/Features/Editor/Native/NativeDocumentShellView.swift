import SwiftUI
import UIKit

/// Shared banner stack above the document surface across classic and native routes.
struct EditorBannerStack: View {
    @Environment(\.docsTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(LocalizationStore.self) private var loc

    let showsOfflineBanner: Bool
    let hasLocalCopy: Bool
    var limitedNativeOfflineRead: Bool = false
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
                OfflineBanner(
                    note: loc[
                        limitedNativeOfflineRead ? .editor_offline_read_only_native : .editor_offline_local_copy]
                )
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
/// Options, Share, header, and subpages) around the `.loading`, `.native`,
/// `.waitingClassicEdits`, `.preservedUnavailable` and `.unavailable` routes.
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
    let copyTextToPasteboard: (String) -> Void

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
    @State private var isConfirmingDiscardWaitingEdits = false
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

    private var isWaitingClassicRoute: Bool {
        if case .waitingClassicEdits = route { return true }
        return false
    }

    private var canEditNative: Bool {
        if case .native(let session) = route {
            return session.input != nil && session.isWritable && session.canType
        }
        return false
    }

    private func editUnavailableReason(for session: NativeEditorSession) -> NativeEditUnavailableReason? {
        if session.input != nil {
            // A peer can bring in content this editor cannot author after the
            // open: the session downgrades `canType` and stops taking input,
            // and says so with the reason an open of such a document shows.
            if !session.canType { return unfamiliarReason(for: session) }
            return session.isWritable ? nil : .noEditAccess
        }
        if let reason = nativeOpen.editUnavailableReason {
            return reason
        }
        if !session.canType { return unfamiliarReason(for: session) }
        return nil
    }

    private func unfamiliarReason(for session: NativeEditorSession) -> NativeEditUnavailableReason {
        if let unfamiliar = session.unfamiliarContent {
            return .unfamiliarContent(blockNode: unfamiliar.node, reason: unfamiliar.reason)
        }
        return .unfamiliarContent(
            blockNode: "",
            reason: session.hasUnsupportedRoot ? "unsupported root" : "unsupported markdown")
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
        onReopenAfterUndo: @escaping () async -> Void,
        copyTextToPasteboard: @escaping (String) -> Void = { UIPasteboard.general.string = $0 }
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
        self.copyTextToPasteboard = copyTextToPasteboard
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
            .onChange(of: nativeSessionIdentity, initial: true) { _, _ in
                syncNativeEditingForCurrentRoute()
            }
            .onChange(of: canEditNative) { _, _ in
                syncNativeEditingForCurrentRoute()
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
            .alert(
                loc[.native_editor_waiting_classic_discard_title],
                isPresented: heldForOutline($isConfirmingDiscardWaitingEdits)
            ) {
                Button(loc[.common_cancel], role: .cancel) {}
                Button(loc[.native_editor_recovery_discard], role: .destructive) {
                    Task {
                        await nativeOpen.discardWaitingClassicEdits(
                            viewModel: viewModel,
                            isOffline: isOffline,
                            canUpdate: pinRow?.abilities.update == true,
                            canMention: pinRow?.abilities.mention == true)
                    }
                }
            } message: {
                Text(loc[.native_editor_waiting_classic_discard_message])
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
                limitedNativeOfflineRead: isWaitingClassicRoute,
                hasConflict: viewModel.visibleNativeSyncConflict != nil,
                showUpdateAvailable: false,
                isDocumentPendingDelete: viewModel.isDocumentPendingDelete,
                errorKey: viewModel.errorKey,
                errorDetail: viewModel.errorDetail,
                onTapConflict: {
                    dismissFocusForConflictSheet()
                    conflictToResolve = viewModel.visibleNativeSyncConflict.map(IdentifiedSyncConflict.init)
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
                    onScrollInteraction: { subpageSwipe = swipeRevealAfterScrollInteraction(subpageSwipe) },
                    externalIsEditing: effectiveNativeEditing,
                    onRequestEdit: enterNativeEditing,
                    onExitEditing: exitNativeEditing
                )
            case .waitingClassicEdits:
                waitingClassicEditsContent
            case .preservedUnavailable:
                preservedUnavailableContent
            case .unavailable(let reason):
                unavailableContent(reason)
            case .classic:
                EmptyView()
            }
        }
        .onChange(of: viewModel.availability.transportOfflineEvidence, initial: true) { _, raw in
            offlineBannerStatus.update(raw)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var waitingClassicEditsContent: some View {
        let waiting = viewModel.waitingClassicContent
        let displayTitle = waiting?.title ?? viewModel.title
        let markdown = waiting?.markdown ?? ""
        let blocks = parseEditorBlocks(markdown)
        let numbering = numberedIndices(in: blocks)
        let noticeState = waitingClassicNoticeState(
            hasConflict: viewModel.visibleNativeSyncConflict != nil,
            isSyncing: nativeOpen.isWaitingClassicSyncing || viewModel.isWaitingClassicInFlight,
            isFailed: viewModel.isWaitingClassicFailed)

        return ScrollView {
            VStack(alignment: .leading, spacing: EditorBlockMetrics.blockSpacing) {
                VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
                    EditorDocumentHeader(
                        title: displayTitle, onEditTitle: nil, reach: reach, peers: []
                    ) {
                        nativeHeaderStatus(session: nil)
                    }
                    if noticeState != .hidden {
                        WaitingClassicEditsNotice(
                            state: noticeState,
                            onRetry: {
                                Task { await nativeOpen.retryWaitingClassicEdits(viewModel: viewModel) }
                            },
                            onCopyText: {
                                copyTextToPasteboard(
                                    waitingClassicCopyText(title: displayTitle, markdown: markdown))
                                toastMessage = ToastMessage(loc[.toast_text_copied])
                            },
                            onDiscard: {
                                isConfirmingDiscardWaitingEdits = true
                            })
                    }
                }
                .padding(.bottom, EditorBlockMetrics.headerToBodySpacing - EditorBlockMetrics.blockSpacing)

                VStack(alignment: .leading, spacing: EditorBlockMetrics.blockSpacing) {
                    ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                        if case .image(let alt, let url) = block.kind,
                            let display = viewModel.pendingAttachmentDisplay(forPlaceholderURL: url)
                        {
                            PendingAttachmentImageView(
                                alt: alt,
                                display: display,
                                showsActions: false,
                                onRetry: {},
                                onRemove: {}
                            )
                            .padding(.leading, EditorBlockMetrics.listIndentInset(block.indent))
                        } else {
                            MarkdownBlockView(
                                block: block,
                                serverOrigin: serverOrigin,
                                numberedIndex: numbering[index],
                                isOffline: isOffline,
                                onToggleChecklist: nil,
                                onTapText: nil
                            )
                        }
                    }
                }
                .textSelection(.enabled)

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

    private var preservedUnavailableContent: some View {
        unavailableContent(
            title: loc[.native_editor_owned_unavailable_title],
            body: loc[.native_editor_owned_unavailable_body],
            icon: .description,
            retry: nil)
    }

    /// The native surface's own error/empty state: a failed fetch, an unreadable
    /// fetched state, a failed seed, or a page never opened on this device.
    private func unavailableContent(_ reason: NativeOpenUnavailable) -> some View {
        let copy: (title: L10nKey, body: L10nKey, icon: MaterialIcon)
        switch reason {
        case .openFailed:
            copy = (.native_editor_open_failed_title, .native_editor_open_failed_body, .error)
        case .unreadableState:
            copy = (.native_editor_unreadable_title, .native_editor_unreadable_body, .warning)
        case .seedFailed:
            copy = (.native_editor_seed_failed_title, .native_editor_seed_failed_body, .warning)
        case .offlineNeverOpened:
            copy = (.native_editor_offline_never_opened_title, .native_editor_offline_never_opened_body, .wifi_off)
        }
        // A page never opened has nothing to retry until the device is back online.
        let offersRetry = reason != .offlineNeverOpened || !showsOfflineStatus
        return unavailableContent(
            title: loc[copy.title],
            body: loc[copy.body],
            icon: copy.icon,
            retry: offersRetry
                ? {
                    Task {
                        await nativeOpen.retry(
                            viewModel: viewModel, isOffline: isOffline,
                            canUpdate: pinRow?.abilities.update == true,
                            canMention: pinRow?.abilities.mention == true)
                    }
                }
                : nil)
    }

    private func unavailableContent(
        title: String, body: String, icon: MaterialIcon, retry: (() -> Void)?
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EditorBlockMetrics.blockSpacing) {
                EditorDocumentHeader(
                    title: viewModel.title, onEditTitle: nil, reach: reach, peers: []
                ) {
                    nativeHeaderStatus(session: nil)
                }
                .padding(.bottom, EditorBlockMetrics.headerToBodySpacing - EditorBlockMetrics.blockSpacing)

                ContentUnavailableView {
                    Label {
                        Text(title)
                    } icon: {
                        MaterialSymbol(icon, size: 44)
                    }
                } description: {
                    Text(body)
                } actions: {
                    if let retry {
                        DocsButton(title: loc[.common_retry], variant: .secondary, action: retry)
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
        .onScrollPhaseChange { _, phase in
            if phase == .interacting {
                subpageSwipe = swipeRevealAfterScrollInteraction(subpageSwipe)
            }
        }
    }

    private func nativeHeader(_ session: NativeEditorSession) -> some View {
        let rawPeers = session.awareness?.peers ?? []
        let peers = presentedPeerCount(peerCount: rawPeers.count, isOffline: isOffline) == nil ? [] : rawPeers
        return VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
            EditorDocumentHeader(
                title: viewModel.title,
                onEditTitle: effectiveNativeEditing
                    ? { nativeOpen.updateTitle($0, viewModel: viewModel) }
                    : nil,
                reach: reach,
                peers: peers,
                onConsumeInitialTitleFocus: {
                    viewModel.consumeNativeInitialTitleFocus(
                        isEditing: effectiveNativeEditing, canEdit: canEditNative)
                }
            ) {
                nativeHeaderStatus(session: session)
            }
            if let reason = editUnavailableReason(for: session) {
                NativeEditUnavailableNotice(reason: reason)
            }
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
                    hasConflict: viewModel.visibleNativeSyncConflict != nil,
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
                hasUnsavedLocalContent: isWaitingClassicRoute ? viewModel.hasWaitingClassicWork : hasUnsaved,
                hasConflict: viewModel.visibleNativeSyncConflict != nil,
                showsOfflineStatus: showsOfflineStatus,
                controlsOffline: isOffline,
                saveState: viewModel.saveState,
                lastSyncedAt: viewModel.lastSyncedAt,
                onRetry: {
                    if isWaitingClassicRoute {
                        Task { await nativeOpen.retryWaitingClassicEdits(viewModel: viewModel) }
                    } else {
                        nativeOpen.saveNow(viewModel: viewModel)
                    }
                })
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
            if effectiveNativeEditing {
                Button {
                    exitNativeEditing()
                } label: {
                    ToolbarIcon(.check, filled: true)
                }
                .buttonBorderShape(.circle)
                .accessibilityLabel(loc[.editor_action_done])
                .accessibilityHidden(presentsPagesTree)
            } else {
                Button {
                    enterNativeEditing()
                } label: {
                    ToolbarIcon(.edit)
                }
                .disabled(!canEditNative)
                .buttonBorderShape(.circle)
                .accessibilityLabel(loc[.editor_action_edit])
                .accessibilityHidden(presentsPagesTree)
            }
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        if editorToolbarActions(
            isEditing: effectiveNativeEditing, isLocal: viewModel.isLocalDocument, isOffline: isOffline
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
            || isConfirmingDiscardWaitingEdits || outlineHeldNavigation.isHolding
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

    private func enterNativeEditing() {
        guard canEditNative else { return }
        if case .native(let session) = route {
            session.setEditing(true)
        }
        isNativeEditing = true
    }

    private func exitNativeEditing() {
        if case .native(let session) = route {
            session.setEditing(false)
        }
        isNativeEditing = false
        viewModel.clearNativeInitialTitleFocus()
    }

    private func syncNativeEditingForCurrentRoute() {
        guard canEditNative else {
            isNativeEditing = false
            viewModel.clearNativeInitialTitleFocus()
            return
        }
        if viewModel.consumeNativeNewDocumentEntryIfNeeded(canEdit: canEditNative) {
            if case .native(let session) = route {
                session.setEditing(true)
            }
            isNativeEditing = true
        } else {
            isNativeEditing = false
        }
    }

    private func nativeSaveStatus(_ session: NativeEditorSession) -> SaveStatusDisplay {
        if session.hasPendingSave || viewModel.hasPendingNativeTitleEdit { return .savedOnDevice }
        let hasConflict = viewModel.visibleNativeSyncConflict != nil
        return saveStatusDisplay(
            saveState: viewModel.saveState, hasConflict: hasConflict,
            hasUnsavedLocalContent: viewModel.isNativeLocalContentUnsaved(
                sessionHasPendingSave: session.hasPendingSave),
            connectionDown: isOffline || viewModel.availability.connectionAppearsDown)
    }
}

/// Explains beneath `EditorDocumentHeader` why native editing is unavailable.
private struct NativeEditUnavailableNotice: View {
    @Environment(\.docsTheme) private var theme
    @Environment(LocalizationStore.self) private var loc

    let reason: NativeEditUnavailableReason

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DocsSpacing.spaceXS) {
            MaterialSymbol(reason.icon, size: 15, relativeTo: .footnote)
            VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
                Text(reason.localizedNote(using: loc))
                    .font(DocsFont.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                if let details = reason.localizedDetailsLine(using: loc) {
                    Text(details)
                        .font(DocsFont.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundStyle(theme.colors.textSecondary)
        .padding(.horizontal, DocsSpacing.spaceSM)
        .padding(.vertical, DocsSpacing.spaceXS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.colors.gray050, in: RoundedRectangle(cornerRadius: DocsRadius.lg))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nativeEditor.editUnavailableNotice")
    }
}

/// Pure display state for the notice card shown below the header on `.waitingClassicEdits`.
enum WaitingClassicNoticeState: Equatable, Sendable {
    case waitingOffline
    case syncing
    case failed
    case hidden
}

/// Maps coordinator/route flags to the waiting-classic notice card state.
/// Conflicts surface through the existing red conflict pill + `ConflictSheetView`.
func waitingClassicNoticeState(
    hasConflict: Bool,
    isSyncing: Bool,
    isFailed: Bool
) -> WaitingClassicNoticeState {
    if hasConflict { return .hidden }
    if isSyncing { return .syncing }
    if isFailed { return .failed }
    return .waitingOffline
}

/// Builds the copyable plain-text payload for waiting classic edits: title, a blank line,
/// and the body Markdown (omitting the blank-line separator when either half is empty).
func waitingClassicCopyText(title: String, markdown: String) -> String {
    switch (title.isEmpty, markdown.isEmpty) {
    case (false, false): return "\(title)\n\n\(markdown)"
    case (false, true): return title
    case (true, false): return markdown
    case (true, true): return ""
    }
}

/// Grey notice card under `EditorDocumentHeader` for the `.waitingClassicEdits` route,
/// matching `NativeEditUnavailableNotice`'s surface and spacing.
struct WaitingClassicEditsNotice: View {
    @Environment(\.docsTheme) private var theme
    @Environment(LocalizationStore.self) private var loc

    let state: WaitingClassicNoticeState
    let onRetry: () -> Void
    let onCopyText: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        switch state {
        case .waitingOffline:
            noticeCard(accessibilityChildren: .combine) {
                HStack(alignment: .firstTextBaseline, spacing: DocsSpacing.spaceXS) {
                    MaterialSymbol(.sync, size: 15, relativeTo: .footnote)
                    Text(loc[.native_editor_waiting_classic_offline])
                        .font(DocsFont.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(theme.colors.textSecondary)
            }
        case .syncing:
            noticeCard(accessibilityChildren: .combine) {
                HStack(alignment: .center, spacing: DocsSpacing.spaceXS) {
                    ProgressView()
                        .controlSize(.small)
                    Text(loc[.native_editor_waiting_classic_syncing])
                        .font(DocsFont.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(theme.colors.textSecondary)
            }
        case .failed:
            noticeCard(accessibilityChildren: .contain) {
                VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
                    HStack(alignment: .firstTextBaseline, spacing: DocsSpacing.spaceXS) {
                        MaterialSymbol(.error, size: 15, relativeTo: .footnote)
                            .foregroundStyle(theme.colors.danger)
                        Text(loc[.native_editor_waiting_classic_failed])
                            .font(DocsFont.footnote)
                            .foregroundStyle(theme.colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: DocsSpacing.spaceXS) {
                            failedActionButtons
                        }
                        VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
                            failedActionButtons
                        }
                    }
                }
            }
        case .hidden:
            EmptyView()
        }
    }

    private func noticeCard<Content: View>(
        accessibilityChildren: AccessibilityChildBehavior,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, DocsSpacing.spaceSM)
            .padding(.vertical, DocsSpacing.spaceXS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.colors.gray050, in: RoundedRectangle(cornerRadius: DocsRadius.lg))
            .accessibilityElement(children: accessibilityChildren)
            .accessibilityIdentifier("nativeEditor.waitingClassicNotice")
    }

    @ViewBuilder
    private var failedActionButtons: some View {
        DocsButton(
            title: loc[.common_retry], variant: .primary, color: .brand, size: .small, action: onRetry
        )
        .accessibilityIdentifier("nativeEditor.waitingClassic.retry")
        DocsButton(
            title: loc[.native_editor_waiting_classic_copy_text], variant: .outline, color: .neutral,
            size: .small, action: onCopyText
        )
        .accessibilityIdentifier("nativeEditor.waitingClassic.copy")
        DocsButton(
            title: loc[.native_editor_recovery_discard], variant: .secondary, color: .danger, size: .small,
            action: onDiscard
        )
        .accessibilityIdentifier("nativeEditor.waitingClassic.discard")
    }
}
