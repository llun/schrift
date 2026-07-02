import SwiftUI

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
        _optionsViewModel = State(initialValue: OptionsViewModel(client: viewModel.client, documentID: viewModel.documentID, isFavorite: initialIsFavorite))
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(
                title: viewModel.title,
                backTitle: "Schrift",
                onBack: onBack,
                trailingActions: trailingActions
            )

            if isOffline {
                OfflineBanner(note: "Editing the copy saved on this device")
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.danger)
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
                viewModel: ShareViewModel(
                    client: viewModel.client,
                    documentID: viewModel.documentID,
                    linkReach: reach,
                    linkRole: linkRole
                ),
                shareURL: documentShareURL(serverHost: serverHost, documentID: viewModel.documentID)
            )
        }
        .sheet(isPresented: $isPresentingOptionsSheet, onDismiss: {
            if pendingShareAfterOptions {
                pendingShareAfterOptions = false
                isPresentingShareSheet = true
            }
        }) {
            OptionsSheetView(
                viewModel: optionsViewModel,
                shareURL: documentShareURL(serverHost: serverHost, documentID: viewModel.documentID),
                markdown: viewModel.currentMarkdown(),
                onShare: { pendingShareAfterOptions = true },
                onDeleted: onDeleted
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
                    if viewModel.mode == .blocks, let query = viewModel.slashQueryText {
                        SlashMenuView(query: query, onSelect: { viewModel.applySlashSelection($0) })
                    }
                    EditorFormattingBar(viewModel: viewModel)
                }
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.bottom, DocsSpacing.spaceXS)
            }
        }
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
                            MarkdownBlockView(block: block, numberedIndex: numberedIndex(of: index, in: viewModel.blocks))
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
            await viewModel.load()
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

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: DocsSpacing.spaceSM) {
            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundStyle(DocsColor.brandFill)

            Text(viewModel.title)
                .font(DocsFont.title1.weight(.bold))
                .tracking(DocsTypographySpec.title1.size * DocsTracking.tight)
                .foregroundStyle(DocsColor.textPrimary)

            HStack(spacing: DocsSpacing.spaceXS) {
                LinkReachPill(reach: reach)
                Text(isOffline ? "Saved on this device" : "Edited just now")
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subpagesSection: some View {
        VStack(alignment: .leading, spacing: DocsSpacing.spaceSM) {
            HStack(spacing: DocsSpacing.space3xs + 1) {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 16))
                Text(viewModel.subpages.isEmpty ? "Subpages" : "Subpages · \(viewModel.subpages.count)")
                    .font(DocsFont.footnote.weight(.semibold))
                    .tracking(DocsTypographySpec.footnote.size * DocsTracking.eyebrow)
            }
            .textCase(.uppercase)
            .foregroundStyle(DocsColor.textTertiary)
            .padding(.horizontal, DocsSpacing.spaceXS)

            if viewModel.subpages.isEmpty {
                Text("Organize this document by creating subpages.")
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.textTertiary)
                    .padding(.horizontal, DocsSpacing.spaceXS)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.subpages) { child in
                        SubpageRow(document: child, onOpen: { onOpenDocument?(child) })
                    }
                }
            }

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
        .padding(.top, DocsSpacing.spaceMD)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DocsColor.borderDefault)
                .frame(height: 1)
        }
    }

    private var trailingActions: [NavBarAction] {
        if viewModel.isEditing {
            return [
                NavBarAction(systemImage: "checkmark", label: "Done", action: { viewModel.finishEditing() }),
            ]
        }
        return [
            NavBarAction(systemImage: "list.bullet.indent", label: "Pages", action: { isPresentingTreePanel = true }),
            NavBarAction(systemImage: "square.and.arrow.up", label: "Share", action: { isPresentingShareSheet = true }),
            NavBarAction(systemImage: "ellipsis", label: "Options", action: {
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
