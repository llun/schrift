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

/// Caption precedence: (1) a **failed save** wins over everything, including the
/// offline wording — it is the only affordance that unpins the document, because
/// `reconcileDraft` deliberately no-ops every revalidation while a failed save's
/// draft is on screen, and the reading surface has no other retry (tap-to-edit is
/// itself blocked offline, which is when saves fail most). (2) other unsaved local
/// content → save wording (a previously-synced doc with a stranded draft must not
/// read "Not synced yet"); (3) synced → "Synced X ago"; (4) neither.
func syncCaption(
    hasUnsavedLocalContent: Bool,
    isOffline: Bool,
    saveState: EditorViewModel.SaveState,
    lastSyncedAt: Date?,
    now: Date,
    locale: Locale
) -> SyncCaption {
    if hasUnsavedLocalContent {
        if case .failed = saveState {
            return SyncCaption(text: .key(.editor_sync_save_failed), offersRetry: true)
        }
        if isOffline { return SyncCaption(text: .key(.editor_sync_saved_on_device), offersRetry: false) }
        switch saveState {
        case .saving: return SyncCaption(text: .key(.editor_saving), offersRetry: false)
        case .saved: return SyncCaption(text: .key(.editor_saved), offersRetry: false)
        case .failed: return SyncCaption(text: .key(.editor_sync_save_failed), offersRetry: true)
        case .dirty, .idle: return SyncCaption(text: .key(.editor_sync_edited_just_now), offersRetry: false)
        }
    }
    if let lastSyncedAt {
        return SyncCaption(
            text: syncStatusCaption(lastSyncedAt: lastSyncedAt, now: now, locale: locale), offersRetry: false)
    }
    return SyncCaption(text: .key(.editor_sync_not_synced_yet), offersRetry: false)
}

struct EditorView: View {
    @Bindable var viewModel: EditorViewModel
    let reach: LinkReach
    let serverHost: String
    var linkRole: LinkRole? = nil
    var initialIsFavorite: Bool = false
    var isOffline: Bool = false
    var onBack: (() -> Void)? = nil
    var onDeleted: (() -> Void)? = nil
    var onOpenDocument: ((Document) -> Void)? = nil

    @Environment(\.scenePhase) private var scenePhase
    @Environment(LocalizationStore.self) private var loc
    @State private var isPresentingShareSheet = false
    @State private var isPresentingOptionsSheet = false
    @State private var isPresentingTreePanel = false
    @State private var pendingShareAfterOptions = false
    @State private var optionsViewModel: OptionsViewModel
    @State private var shareViewModel: ShareViewModel
    @State private var selectedPhotoItem: PhotosPickerItem?

    init(
        viewModel: EditorViewModel,
        reach: LinkReach,
        serverHost: String,
        linkRole: LinkRole? = nil,
        initialIsFavorite: Bool = false,
        isOffline: Bool = false,
        onBack: (() -> Void)? = nil,
        onDeleted: (() -> Void)? = nil,
        onOpenDocument: ((Document) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.reach = reach
        self.serverHost = serverHost
        self.linkRole = linkRole
        self.initialIsFavorite = initialIsFavorite
        self.isOffline = isOffline
        self.onBack = onBack
        self.onDeleted = onDeleted
        self.onOpenDocument = onOpenDocument
        _optionsViewModel = State(
            initialValue: OptionsViewModel(
                client: viewModel.client, documentID: viewModel.documentID, isFavorite: initialIsFavorite))
        _shareViewModel = State(
            initialValue: ShareViewModel(
                client: viewModel.client, documentID: viewModel.documentID, linkReach: reach, linkRole: linkRole))
    }

    var body: some View {
        VStack(spacing: 0) {
            // In reading mode the document title is the large-title header
            // (uniform 96pt bar, matching every other screen). While editing,
            // the title is edited inline in the canvas, so the bar collapses to
            // the compact form and drops its title to avoid showing it twice.
            NavBar(
                title: viewModel.isEditing ? "" : viewModel.title,
                largeTitle: !viewModel.isEditing,
                backTitle: loc[.home_title],
                onBack: onBack,
                trailingActions: trailingActions
            )

            if isOffline, viewModel.hasLocalCopy {
                OfflineBanner(note: loc[.editor_offline_local_copy])
            }

            if viewModel.updateAvailable, !viewModel.isEditing {
                Button {
                    viewModel.applyPendingUpdate()
                } label: {
                    HStack(spacing: DocsSpacing.space2xs) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13))
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

            if let errorKey = viewModel.errorKey {
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
        .background(DocsColor.surfacePage)
        .overlay {
            DocTreePanel(
                rootTitle: viewModel.title,
                client: viewModel.client,
                rootID: viewModel.documentID,
                currentID: viewModel.documentID,
                isOpen: isPresentingTreePanel,
                childrenCache: viewModel.childrenCache,
                onOpen: { document in onOpenDocument?(document) },
                onClose: { isPresentingTreePanel = false },
                onNewPage: {
                    isPresentingTreePanel = false
                    Task {
                        if let child = await viewModel.addSubpage() {
                            onOpenDocument?(child)
                        }
                    }
                }
            )
        }
        .task {
            await viewModel.load()
        }
        .onDisappear {
            viewModel.flushPendingChanges()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                viewModel.flushPendingChanges()
            }
        }
        .sheet(isPresented: $isPresentingShareSheet) {
            ShareSheetView(
                viewModel: shareViewModel,
                shareURL: documentShareURL(serverHost: serverHost, documentID: viewModel.documentID)
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(
            isPresented: $isPresentingOptionsSheet,
            onDismiss: {
                if pendingShareAfterOptions {
                    pendingShareAfterOptions = false
                    isPresentingShareSheet = true
                }
            }
        ) {
            OptionsSheetView(
                viewModel: optionsViewModel,
                shareURL: documentShareURL(serverHost: serverHost, documentID: viewModel.documentID),
                markdown: viewModel.currentMarkdown(),
                onShare: { pendingShareAfterOptions = true },
                onDeleted: {
                    viewModel.handleDidDelete()
                    onDeleted?()
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Editing

    private var editingSurface: some View {
        VStack(spacing: 0) {
            EditorSaveBar(
                saveState: viewModel.saveState,
                onSaveTap: { viewModel.saveNow() }
            )

            BlockEditorView(viewModel: viewModel)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: DocsSpacing.spaceXS) {
                        if viewModel.isUploadingPhoto {
                            uploadingPhotoBanner
                        }
                        if let query = viewModel.slashQueryText {
                            SlashMenuView(query: query, onSelect: { viewModel.applySlashSelection($0) })
                        }
                        EditorFormattingBar(viewModel: viewModel)
                    }
                    .padding(.horizontal, DocsSpacing.gutter)
                    .padding(.bottom, DocsSpacing.spaceXS)
                }
        }
        // The out-of-process system picker: no photo-library usage description and
        // no project.yml change are needed. Do NOT add `photoLibrary: .shared()` —
        // that makes it in-process and would require NSPhotoLibraryUsageDescription.
        .photosPicker(isPresented: $viewModel.isPhotoPickerPresented, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            // Clear immediately so re-picking the same asset fires onChange again.
            selectedPhotoItem = nil
            Task {
                await viewModel.insertPhoto(loadingData: { try await newItem.loadTransferable(type: Data.self) })
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

    private var uploadingPhotoBanner: some View {
        HStack(spacing: DocsSpacing.spaceXS) {
            ProgressView()
            Text(loc[.editor_uploading_photo])
                .font(DocsFont.footnote)
                .foregroundStyle(DocsColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DocsSpacing.spaceSM)
        .padding(.vertical, DocsSpacing.spaceXS)
        .background(DocsColor.surfaceSunken, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(loc[.editor_uploading_photo_a11y])
    }

    // MARK: - Reading

    private var readingSurface: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DocsSpacing.spaceMD) {
                headerBlock

                if viewModel.blocks.isEmpty {
                    if viewModel.errorKey == nil {
                        emptyContent
                    }
                } else {
                    VStack(alignment: .leading, spacing: DocsSpacing.spaceSM) {
                        ForEach(Array(viewModel.blocks.enumerated()), id: \.element.id) { index, block in
                            MarkdownBlockView(
                                block: block, numberedIndex: numberedIndex(of: index, in: viewModel.blocks)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard !isOffline else { return }
                                viewModel.startEditing(focusing: block.id)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                subpagesSection
            }
            .padding(.horizontal, DocsSpacing.spaceMD - DocsSpacing.space4xs)
            .padding(.top, DocsSpacing.spaceSM)
            .padding(.bottom, DocsSpacing.spaceLG)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .refreshable {
            await viewModel.refresh()
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
            Label(loc[.editor_empty_title], systemImage: "doc.text")
        } description: {
            Text(loc[.editor_empty_body])
        } actions: {
            if !isOffline {
                Button(loc[.editor_start_writing]) {
                    viewModel.startEditing()
                }
                .font(DocsFont.body)
                .foregroundStyle(DocsColor.textBrand)
            }
        }
        .padding(.top, DocsSpacing.spaceLG)
    }

    /// The document title now lives in the large-title nav bar (uniform 96pt
    /// header across the app), so the in-content header only carries the
    /// reach/sync metadata that has no place in the bar.
    private var headerBlock: some View {
        HStack(spacing: DocsSpacing.spaceXS) {
            LinkReachPill(reach: reach)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let caption = currentSyncCaption(now: context.date)
                if caption.offersRetry {
                    Button {
                        viewModel.saveNow()
                    } label: {
                        Text(resolvedCaption(caption.text))
                            .font(DocsFont.footnote)
                            .foregroundStyle(DocsColor.textBrand)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(loc[.editor_sync_save_failed_a11y])
                } else {
                    Text(resolvedCaption(caption.text))
                        .font(DocsFont.footnote)
                        .foregroundStyle(DocsColor.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subpagesSection: some View {
        // 40pt above the rule, 16pt below it before the header (reference spacing).
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(DocsColor.borderDefault)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DocsSpacing.space2xs) {
                    Image(systemName: "list.bullet.indent")
                        .font(.system(size: 16))
                        .accessibilityHidden(true)
                    Text(
                        (viewModel.subpages?.isEmpty ?? true)
                            ? loc[.editor_subpages_title]
                            : loc.format(.editor_subpages_title_count, viewModel.subpages?.count ?? 0)
                    )
                    .font(DocsFont.footnote.weight(.semibold))
                    .tracking(DocsTypographySpec.footnote.size * DocsTracking.eyebrow)
                }
                .textCase(.uppercase)
                .foregroundStyle(DocsColor.textTertiary)
                .padding(.horizontal, DocsSpacing.spaceXS)
                // The eyebrow hugs the first row (reference 4pt), not a 12pt gap.
                .padding(.bottom, DocsSpacing.space3xs)

                if let subpages = viewModel.subpages {
                    if subpages.isEmpty {
                        Text(loc[.editor_subpages_empty])
                            .font(DocsFont.footnote)
                            .foregroundStyle(DocsColor.textTertiary)
                            .padding(.horizontal, DocsSpacing.spaceXS)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(subpages) { child in
                                SubpageRow(document: child, onOpen: { onOpenDocument?(child) })
                            }
                        }
                    }
                }
                // nil (never fetched or cached): just the eyebrow — never claim "no subpages".

                if !isOffline {
                    Button {
                        Task {
                            if let child = await viewModel.addSubpage() {
                                onOpenDocument?(child)
                            }
                        }
                    } label: {
                        HStack(spacing: DocsSpacing.spaceXS) {
                            Image(systemName: "plus")
                                .font(.system(size: 22))
                            Text(loc[.editor_add_subpage])
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(DocsColor.textBrand)
                        .padding(.horizontal, DocsSpacing.spaceXS)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, DocsSpacing.spaceBase)
        }
        // The reading surface already puts spaceMD between blocks, so this only
        // needs to add the remainder to reach the reference's 40pt gap.
        .padding(.top, DocsSpacing.spaceXL - DocsSpacing.spaceMD)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func currentSyncCaption(now: Date) -> SyncCaption {
        syncCaption(
            hasUnsavedLocalContent: viewModel.hasUnsavedLocalContent,
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

    private var trailingActions: [NavBarAction] {
        if viewModel.isEditing {
            return [
                NavBarAction(
                    systemImage: "checkmark", label: loc[.editor_action_done], action: { viewModel.finishEditing() })
            ]
        }
        return [
            NavBarAction(
                systemImage: "list.bullet.indent", label: loc[.editor_action_pages],
                action: { isPresentingTreePanel = true }),
            NavBarAction(
                systemImage: "square.and.arrow.up", label: loc[.editor_action_share],
                action: { isPresentingShareSheet = true }),
            NavBarAction(
                systemImage: "ellipsis", label: loc[.editor_action_options],
                action: {
                    isPresentingOptionsSheet = true
                }),
        ]
    }
}

#Preview {
    let client = DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)
    EditorView(
        viewModel: EditorViewModel(
            client: client,
            documentID: UUID(),
            title: "Q3 Planning",
            saveCoordinator: DocumentSaveCoordinator(client: client, backgroundTasks: .noop)
        ),
        reach: .restricted,
        serverHost: "docs.llun.dev"
    )
    .environment(LocalizationStore())
}
