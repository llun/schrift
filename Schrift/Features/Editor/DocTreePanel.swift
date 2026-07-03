import SwiftUI

/// Shared lazy-loading state for the document tree. Kept as an `@Observable`
/// model so the recursive `DocTreeNode` views can share one cache + expansion set.
@MainActor
@Observable
final class DocTreeModel {
    var childrenCache: [UUID: [Document]] = [:]
    var expanded: Set<UUID> = []

    private let client: DocsAPIClient
    init(client: DocsAPIClient) { self.client = client }

    func children(of id: UUID) -> [Document] { childrenCache[id] ?? [] }
    func isExpanded(_ id: UUID) -> Bool { expanded.contains(id) }
    /// Whether the children for `id` have finished loading (cache populated).
    func isLoaded(_ id: UUID) -> Bool { childrenCache[id] != nil }

    func expand(_ id: UUID) { expanded.insert(id) }

    func toggle(_ id: UUID) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
            if childrenCache[id] == nil {
                Task { await loadChildren(of: id) }
            }
        }
    }

    func loadChildren(of id: UUID) async {
        guard childrenCache[id] == nil else { return }
        childrenCache[id] = (try? await client.listChildren(documentID: id))?.results ?? []
    }
}

struct DocTreePanel: View {
    let rootTitle: String
    let client: DocsAPIClient
    let rootID: UUID
    var currentID: UUID
    var isOpen: Bool
    var onOpen: (Document) -> Void
    var onClose: () -> Void
    var onNewPage: (() -> Void)? = nil

    private let panelWidth: CGFloat = 306
    @State private var model: DocTreeModel

    init(
        rootTitle: String,
        client: DocsAPIClient,
        rootID: UUID,
        currentID: UUID,
        isOpen: Bool,
        onOpen: @escaping (Document) -> Void,
        onClose: @escaping () -> Void,
        onNewPage: (() -> Void)? = nil
    ) {
        self.rootTitle = rootTitle
        self.client = client
        self.rootID = rootID
        self.currentID = currentID
        self.isOpen = isOpen
        self.onOpen = onOpen
        self.onClose = onClose
        self.onNewPage = onNewPage
        _model = State(initialValue: DocTreeModel(client: client))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if isOpen {
                DocsColor.surfaceScrim
                    .ignoresSafeArea()
                    .onTapGesture { onClose() }
                    .transition(.opacity)

                panel
                    .frame(width: panelWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    // Extend only the surface into the bottom safe area (so the
                    // scrim doesn't show through beneath the sidebar); the content
                    // stack keeps its inset so the New page button clears the home
                    // indicator.
                    .background(DocsColor.surfacePage.ignoresSafeArea(edges: .bottom))
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(DocsColor.borderDefault)
                            .frame(width: 0.5)
                    }
                    .shadow(color: DocsColor.textPrimary.opacity(0.16), radius: 16, x: 4, y: 0)
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isOpen)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pages")
                    .font(DocsFont.headline)
                    .foregroundStyle(DocsColor.textPrimary)
                Spacer()
                IconButton(systemImage: "sidebar.left", label: "Close pages", variant: .ghost, color: .neutral) {
                    onClose()
                }
            }
            .padding(.leading, DocsSpacing.spaceBase)
            .padding(.trailing, DocsSpacing.space2xs)
            .frame(height: DocsSpacing.navBarHeight)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DocTreeRow(
                        title: rootTitle,
                        depth: 0,
                        hasChildren: !model.children(of: rootID).isEmpty,
                        isSelected: currentID == rootID,
                        isExpanded: model.isExpanded(rootID),
                        isRoot: true,
                        onToggle: { model.toggle(rootID) },
                        onSelect: { onClose() }
                    )
                    .padding(.bottom, DocsSpacing.space2xs)

                    if model.isExpanded(rootID) {
                        ForEach(model.children(of: rootID)) { child in
                            DocTreeNode(
                                model: model,
                                document: child,
                                depth: 0,
                                currentID: currentID,
                                onOpen: onOpen,
                                onClose: onClose
                            )
                        }
                    }

                    if model.isLoaded(rootID), model.children(of: rootID).isEmpty {
                        Text("No subpages yet. Add one to organize this document.")
                            .font(DocsFont.footnote)
                            .foregroundStyle(DocsColor.textTertiary)
                            .padding(.horizontal, DocsSpacing.spaceSM)
                            .padding(.vertical, DocsSpacing.space4xs)
                    }
                }
                .padding(.horizontal, DocsSpacing.spaceXS)
                .padding(.vertical, DocsSpacing.spaceXS)
            }

            if let onNewPage {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(DocsColor.borderDefault)
                        .frame(height: 1)
                    HStack {
                        DocsButton(title: "New page", variant: .tertiary, color: .brand, size: .small, icon: "plus") {
                            onNewPage()
                        }
                        Spacer()
                    }
                    .padding(.horizontal, DocsSpacing.spaceSM)
                    .padding(.top, DocsSpacing.spaceXS)
                    .padding(.bottom, DocsSpacing.spaceSM + DocsSpacing.space4xs)
                }
            }
        }
        .task {
            await model.loadChildren(of: rootID)
            model.expand(rootID)
        }
    }
}

/// One node + (when expanded) its children — a recursive named View, which is
/// legal where a recursive `@ViewBuilder` func's opaque `some View` is not.
private struct DocTreeNode: View {
    let model: DocTreeModel
    let document: Document
    let depth: Int
    let currentID: UUID
    var onOpen: (Document) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DocTreeRow(
                title: displayTitle(document),
                depth: depth,
                hasChildren: document.numchild > 0,
                isSelected: currentID == document.id,
                isExpanded: model.isExpanded(document.id),
                onToggle: { model.toggle(document.id) },
                onSelect: {
                    onOpen(document)
                    onClose()
                }
            )

            if model.isExpanded(document.id) {
                ForEach(model.children(of: document.id)) { child in
                    DocTreeNode(
                        model: model,
                        document: child,
                        depth: depth + 1,
                        currentID: currentID,
                        onOpen: onOpen,
                        onClose: onClose
                    )
                }
            }
        }
    }

    private func displayTitle(_ document: Document) -> String {
        let trimmed = document.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled document" : trimmed
    }
}

/// Presentational row for a single tree entry.
private struct DocTreeRow: View {
    let title: String
    let depth: Int
    let hasChildren: Bool
    let isSelected: Bool
    let isExpanded: Bool
    var isRoot: Bool = false
    var onToggle: () -> Void
    var onSelect: () -> Void

    private var background: Color {
        if isSelected { return DocsColor.brandFillSubtle }
        return isRoot ? DocsColor.surfaceSunken : Color.clear
    }

    var body: some View {
        HStack(spacing: DocsSpacing.space2xs) {
            if !isRoot {
                Button(action: onToggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18))
                        .foregroundStyle(hasChildren ? DocsColor.textTertiary : Color.clear)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        // Keep the ~18pt reference chevron column width so the icon/
                        // title don't shift right, but let the hit area fill the row
                        // height so a near miss toggles rather than opening the doc.
                        .frame(width: 20, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasChildren)
            }

            // Reference renders the tree glyph at size + 3 (root 21, child 19).
            DocIcon(size: isRoot ? 21 : 19)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 15, weight: (isSelected || isRoot) ? .semibold : .regular))
                .foregroundStyle(isSelected ? DocsColor.textBrand : DocsColor.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.leading, DocsSpacing.spaceXS + CGFloat(depth) * 18)
        .padding(.trailing, DocsSpacing.spaceXS)
        .frame(minHeight: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: DocsRadius.md))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

#Preview {
    DocTreePanel(
        rootTitle: "Q3 Planning",
        client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!),
        rootID: UUID(),
        currentID: UUID(),
        isOpen: true,
        onOpen: { _ in },
        onClose: {}
    )
}
