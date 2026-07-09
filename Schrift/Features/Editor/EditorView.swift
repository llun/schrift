import PhotosUI
import SwiftUI

/// "Synced X ago" caption for the editor header. Pure — `now` is a parameter
/// (note `documentRowDate` reads `Date()` internally and is untestable; this
/// one is driven by a `TimelineView` tick so it must not).
func syncStatusCaption(lastSyncedAt: Date, now: Date) -> String {
    if now.timeIntervalSince(lastSyncedAt) < 60 {
        return "Synced just now"
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return "Synced \(formatter.localizedString(for: lastSyncedAt, relativeTo: now))"
}

/// The editor header's sync caption, and whether it doubles as a retry button.
struct SyncCaption: Equatable {
    let text: String
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
    now: Date
) -> SyncCaption {
    if hasUnsavedLocalContent {
        if case .failed = saveState {
            return SyncCaption(text: "Couldn't save · tap to retry", offersRetry: true)
        }
        if isOffline { return SyncCaption(text: "Saved on this device", offersRetry: false) }
        switch saveState {
        case .saving: return SyncCaption(text: "Saving…", offersRetry: false)
        case .saved: return SyncCaption(text: "Saved", offersRetry: false)
        case .failed: return SyncCaption(text: "Couldn't save · tap to retry", offersRetry: true)
        case .dirty, .idle: return SyncCaption(text: "Edited just now", offersRetry: false)
        }
    }
    if let lastSyncedAt {
        return SyncCaption(text: syncStatusCaption(lastSyncedAt: lastSyncedAt, now: now), offersRetry: false)
    }
    return SyncCaption(text: "Not synced yet", offersRetry: false)
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
                backTitle: "Schrift",
                onBack: onBack,
                trailingActions: trailingActions
            )

            if isOffline, viewModel.hasLocalCopy {
                OfflineBanner(note: "Reading the copy saved on this device")
            }

            if viewModel.updateAvailable, !viewModel.isEditing {
                Button {
                    viewModel.applyPendingUpdate()
                } label: {
                    HStack(spacing: DocsSpacing.space2xs) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13))
                        Text("Document updated · tap to refresh")
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
                .accessibilityLabel("Document updated. Tap to refresh.")
            }

            if let errorMessage = viewModel.errorMessage {
                VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
                    Text(errorMessage)
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
        }
    }

    // MARK: - Editing

    private var editingSurface: some View {
        VStack(spacing: 0) {
            EditorModeBar(
                modeIndex: Binding(
                    get: { viewModel.mode == .markdown ? 1 : 0 },
                    set: { viewModel.setMode($0 == 1 ? .markdown : .blocks) }
                ),
                saveState: viewModel.saveState,
                onSaveTap: { viewModel.saveNow() }
            )

            if viewModel.openInMarkdownMode, viewModel.mode == .markdown {
                Text("Some content in this document can't be edited as blocks yet, so it opens as Markdown.")
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DocsSpacing.gutter)
                    .padding(.top, DocsSpacing.space3xs)
            }

            Group {
                if viewModel.mode == .markdown {
                    MarkdownSourceView(viewModel: viewModel)
                } else {
                    BlockEditorView(viewModel: viewModel)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: DocsSpacing.spaceXS) {
                    if viewModel.isUploadingPhoto {
                        uploadingPhotoBanner
                    }
                    if viewModel.mode == .blocks, let query = viewModel.slashQueryText {
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
    }

    private var uploadingPhotoBanner: some View {
        HStack(spacing: DocsSpacing.spaceXS) {
            ProgressView()
            Text("Uploading photo…")
                .font(DocsFont.footnote)
                .foregroundStyle(DocsColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DocsSpacing.spaceSM)
        .padding(.vertical, DocsSpacing.spaceXS)
        .background(DocsColor.surfaceSunken, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Uploading photo")
    }

    // MARK: - Reading

    private var readingSurface: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DocsSpacing.spaceMD) {
                headerBlock

                if viewModel.blocks.isEmpty {
                    if viewModel.errorMessage == nil {
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
    }

    private var emptyContent: some View {
        ContentUnavailableView {
            Label("Empty document", systemImage: "doc.text")
        } description: {
            Text("This document doesn't have any content yet.")
        } actions: {
            if !isOffline {
                Button("Start writing") {
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
                        Text(caption.text)
                            .font(DocsFont.footnote)
                            .foregroundStyle(DocsColor.textBrand)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Couldn't save. Tap to retry.")
                } else {
                    Text(caption.text)
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
                            ? "Subpages" : "Subpages · \(viewModel.subpages?.count ?? 0)"
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
                        Text("Organize this document by creating subpages.")
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
                            Text("Add a subpage")
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
            now: now
        )
    }

    private var trailingActions: [NavBarAction] {
        if viewModel.isEditing {
            return [
                NavBarAction(systemImage: "checkmark", label: "Done", action: { viewModel.finishEditing() })
            ]
        }
        return [
            NavBarAction(systemImage: "list.bullet.indent", label: "Pages", action: { isPresentingTreePanel = true }),
            NavBarAction(systemImage: "square.and.arrow.up", label: "Share", action: { isPresentingShareSheet = true }),
            NavBarAction(
                systemImage: "ellipsis", label: "Options",
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
}
