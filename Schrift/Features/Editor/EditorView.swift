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

    @State private var isPresentingShareSheet = false
    @State private var isPresentingOptionsSheet = false
    @State private var isPresentingTreePanel = false
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
                offlineBanner
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
                ZStack(alignment: .bottom) {
                    TextEditor(text: $viewModel.rawMarkdown)
                        .font(DocsFont.body)
                        .padding(.horizontal, DocsSpacing.spaceXS)
                        .disabled(viewModel.isSaving)

                    EditorFormattingBar(onInsert: { token in
                        viewModel.rawMarkdown += token
                    })
                    .padding(.bottom, DocsSpacing.spaceBase)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DocsSpacing.spaceMD) {
                        headerBlock

                        if viewModel.blocks.isEmpty {
                            if viewModel.errorMessage == nil {
                                ContentUnavailableView(
                                    "Empty document",
                                    systemImage: "doc.text",
                                    description: Text("This document doesn't have any content yet.")
                                )
                                .padding(.top, DocsSpacing.spaceLG)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: DocsSpacing.spaceSM) {
                                ForEach(Array(viewModel.blocks.enumerated()), id: \.offset) { _, block in
                                    MarkdownBlockView(block: block)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        subpagesSection
                    }
                    .padding(DocsSpacing.gutter)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .refreshable {
                    await viewModel.load()
                }
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
                onClose: { isPresentingTreePanel = false }
            )
        }
        .task {
            await viewModel.load()
        }
        .sheet(isPresented: $isPresentingShareSheet) {
            ShareSheetView(
                viewModel: ShareViewModel(
                    client: viewModel.client,
                    documentID: viewModel.documentID,
                    linkReach: reach,
                    linkRole: linkRole
                )
            )
        }
        .sheet(isPresented: $isPresentingOptionsSheet) {
            OptionsSheetView(
                viewModel: optionsViewModel,
                shareURL: documentShareURL(serverHost: serverHost, documentID: viewModel.documentID),
                markdown: viewModel.rawMarkdown,
                onDeleted: onDeleted
            )
        }
    }

    private var offlineBanner: some View {
        HStack(spacing: DocsSpacing.spaceXS) {
            Image(systemName: "checkmark.icloud")
                .foregroundStyle(DocsColor.textSecondary)
            VStack(alignment: .leading, spacing: 0) {
                Text("Offline")
                    .font(DocsFont.caption.weight(.bold))
                    .foregroundStyle(DocsColor.textSecondary)
                Text("Editing the copy saved on this device")
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.textTertiary)
            }
            Spacer()
        }
        .padding(.horizontal, DocsSpacing.gutter)
        .padding(.vertical, DocsSpacing.spaceXS)
        .background(DocsColor.surfaceSunken)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DocsColor.borderDefault)
                .frame(height: 0.5)
        }
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: DocsSpacing.spaceSM) {
            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundStyle(DocsColor.brandFill)

            Text(viewModel.title)
                .font(DocsFont.title1.weight(.bold))
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
            HStack(spacing: DocsSpacing.space3xs) {
                Image(systemName: "list.bullet.indent")
                Text("Subpages · \(viewModel.subpages.count)")
            }
            .font(DocsFont.footnote)
            .textCase(.uppercase)
            .foregroundStyle(DocsColor.textTertiary)

            if viewModel.subpages.isEmpty {
                Text("Organize this document by creating subpages.")
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.textTertiary)
                    .padding(.horizontal, DocsSpacing.spaceBase)
                    .frame(minHeight: DocsSpacing.rowMinHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.subpages.enumerated()), id: \.element.id) { index, child in
                        if index > 0 {
                            Rectangle()
                                .fill(DocsColor.borderDefault)
                                .frame(height: 0.5)
                                .padding(.leading, DocsSpacing.spaceBase)
                        }
                        SubpageRow(document: child, onOpen: { onOpenDocument?(child) })
                    }
                }
                .background(DocsColor.surfacePage)
                .overlay(
                    RoundedRectangle(cornerRadius: DocsRadius.lg)
                        .strokeBorder(DocsColor.borderDefault, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: DocsRadius.lg))
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
                    Text("Add a subpage")
                    Spacer()
                }
                .font(DocsFont.body)
                .foregroundStyle(DocsColor.textBrand)
                .padding(.horizontal, DocsSpacing.spaceBase)
                .frame(minHeight: DocsSpacing.rowMinHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trailingActions: [NavBarAction] {
        if viewModel.isEditing {
            return [
                NavBarAction(systemImage: "xmark", label: "Cancel", action: { viewModel.cancelEditing() }),
                NavBarAction(systemImage: "checkmark", label: "Save", action: { Task { await viewModel.save() } }),
            ]
        }
        return [
            NavBarAction(systemImage: "sidebar.left", label: "Pages", action: { isPresentingTreePanel = true }),
            NavBarAction(systemImage: "square.and.arrow.up", label: "Share", action: { isPresentingShareSheet = true }),
            NavBarAction(systemImage: "pencil", label: "Edit", action: { viewModel.startEditing() }),
            NavBarAction(systemImage: "ellipsis", label: "Options", action: {
                isPresentingOptionsSheet = true
            }),
        ]
    }
}

#Preview {
    EditorView(
        viewModel: EditorViewModel(
            client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!),
            documentID: UUID(),
            title: "Q3 Planning"
        ),
        reach: .restricted,
        serverHost: "docs.llun.dev"
    )
}
