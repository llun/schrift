import SwiftUI

/// The picker with its view model owned in `@State`, for the two surfaces that present it from
/// a `.sheet(item:)`.
///
/// The view model may **not** be built inline in that closure. `MoveDocumentSheetView.viewModel`
/// is a stored property, so SwiftUI re-running the sheet's content builder — which a parent
/// re-render does, and both presenters re-render constantly — would swap in a fresh model with
/// no destinations, while the presented view's identity is unchanged so its `.task` never runs
/// again: an open picker would empty itself and stay empty. Owning it here keeps
/// `.sheet(item:)`'s per-document identity *and* survives the re-render, which is the same rule
/// the editor's Options and Share models follow.
struct MoveDocumentSheet: View {
    @State private var viewModel: MoveDocumentViewModel

    init(
        client: DocsAPIClient,
        document: Document,
        saveCoordinator: DocumentSaveCoordinator?,
        signedInUser: SignedInUserStore
    ) {
        _viewModel = State(
            initialValue: MoveDocumentViewModel(
                client: client, documentID: document.id, row: document,
                saveCoordinator: saveCoordinator, signedInUser: signedInUser))
    }

    var body: some View {
        MoveDocumentSheetView(viewModel: viewModel)
    }
}

/// Pick where a document should live: the top level, or any top-level document to file it under.
///
/// A flat, boxless list under the shared `SheetHeader`, like every other list-bearing sheet
/// here — no card, no dividers, structure from an eyebrow label and spacing.
///
/// There is no confirmation step, deliberately: choosing a destination *is* the deliberate
/// act, and a move is not destructive — the document keeps its content, its sub-pages travel
/// with it, and moving it back is the same two taps.
struct MoveDocumentSheetView: View {
    @Bindable var viewModel: MoveDocumentViewModel
    /// Called once the move has landed, so the presenter can close whatever it was presented
    /// from. The lists themselves are updated by the coordinator's announcement, not here.
    var onMoved: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: loc[.move_title], closeLabel: loc[.common_close], onClose: { dismiss() })

            if let errorKey = viewModel.errorKey {
                Text(loc[errorKey])
                    .font(DocsFont.footnote)
                    .foregroundStyle(DocsColor.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DocsSpacing.gutter)
                    .padding(.bottom, DocsSpacing.spaceXS)
            }

            ScrollView {
                VStack(spacing: 0) {
                    // A spinner while the first load is in flight or a move is being sent —
                    // the body renders before `.task` runs, so without it the empty state
                    // flashes on every open, and an in-flight move would otherwise read as a
                    // frozen sheet.
                    if !viewModel.hasLoaded || viewModel.isMoving {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, DocsSpacing.spaceMD)
                    }

                    if viewModel.offersHome {
                        ListRow(
                            icon: .description, title: loc[.move_home],
                            action: { Task { await run { await viewModel.moveToHome() } } })
                    }

                    if !viewModel.destinations.isEmpty || !viewModel.localDestinations.isEmpty {
                        sectionLabel(loc[.move_destinations])
                    }

                    ForEach(viewModel.localDestinations) { destination in
                        destinationRow(destination)
                    }
                    ForEach(viewModel.destinations) { destination in
                        destinationRow(destination)
                    }

                    if viewModel.isEmpty {
                        Text(loc[.move_empty])
                            .font(DocsFont.footnote)
                            .foregroundStyle(DocsColor.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DocsSpacing.gutter)
                            .padding(.top, DocsSpacing.spaceSM)
                    }
                }
                .padding(.bottom, DocsSpacing.spaceSM)
                // The list alone, never the header: disabling the whole sheet would take the
                // close button with it and leave an in-flight move looking unclosable.
                .disabled(viewModel.isMoving)
            }
        }
        .background(DocsColor.surfacePage)
        .task { await viewModel.loadDestinations() }
    }

    private func destinationRow(_ destination: Document) -> some View {
        ListRow(
            icon: .description,
            title: destination.title ?? loc[.common_untitled],
            action: { Task { await run { await viewModel.move(under: destination) } } })
    }

    /// The uppercase eyebrow that gives a sheet's list its structure, since a sheet never
    /// boxes one.
    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(DocsFont.footnote)
            .foregroundStyle(DocsColor.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DocsSpacing.gutter)
            .padding(.top, DocsSpacing.spaceMD)
            .padding(.bottom, DocsSpacing.spaceXS)
    }

    /// Run a move and, if it landed, close — telling the presenter, which may have its own
    /// sheet to dismiss behind this one. A failure leaves the sheet up with its error, so the
    /// user can pick somewhere else.
    private func run(_ move: () async -> Void) async {
        await move()
        if viewModel.didMove {
            dismiss()
            onMoved?()
        }
    }
}

#Preview {
    let client = DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)
    let document = Document(
        id: UUID(), title: "Meeting notes", excerpt: nil, abilities: DocumentAbilities(),
        linkReach: .restricted, linkRole: .reader, computedLinkReach: nil, computedLinkRole: nil,
        isFavorite: false, depth: 2, numchild: 0, path: "00010001", createdAt: .now, updatedAt: .now,
        userRole: .owner, creator: nil)
    MoveDocumentSheetView(
        viewModel: MoveDocumentViewModel(client: client, documentID: document.id, row: document)
    )
    .environment(LocalizationStore())
}
