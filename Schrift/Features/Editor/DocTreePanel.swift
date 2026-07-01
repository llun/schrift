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

    private let panelWidth: CGFloat = 300
    @State private var model: DocTreeModel

    init(
        rootTitle: String,
        client: DocsAPIClient,
        rootID: UUID,
        currentID: UUID,
        isOpen: Bool,
        onOpen: @escaping (Document) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.rootTitle = rootTitle
        self.client = client
        self.rootID = rootID
        self.currentID = currentID
        self.isOpen = isOpen
        self.onOpen = onOpen
        self.onClose = onClose
        _model = State(initialValue: DocTreeModel(client: client))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if isOpen {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { onClose() }
                    .transition(.opacity)

                panel
                    .frame(width: panelWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(DocsColor.surfacePage)
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
            .padding(.horizontal, DocsSpacing.spaceBase)
            .frame(height: DocsSpacing.navBarHeight)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(DocsColor.borderDefault)
                    .frame(height: 0.5)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DocTreeRow(
                        title: rootTitle,
                        depth: 0,
                        hasChildren: !model.children(of: rootID).isEmpty,
                        isSelected: currentID == rootID,
                        isExpanded: model.isExpanded(rootID),
                        onToggle: { model.toggle(rootID) },
                        onSelect: { model.toggle(rootID) }
                    )

                    if model.isExpanded(rootID) {
                        ForEach(model.children(of: rootID)) { child in
                            DocTreeNode(
                                model: model,
                                document: child,
                                depth: 1,
                                currentID: currentID,
                                onOpen: onOpen,
                                onClose: onClose
                            )
                        }
                    }
                }
                .padding(.vertical, DocsSpacing.spaceXS)
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
    var onToggle: () -> Void
    var onSelect: () -> Void

    var body: some View {
        HStack(spacing: DocsSpacing.spaceXS) {
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(DocsFont.caption)
                    .foregroundStyle(hasChildren ? DocsColor.textSecondary : Color.clear)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasChildren)

            DocIcon(size: 20, tinted: isSelected)

            Text(title)
                .font(DocsFont.subhead)
                .foregroundStyle(isSelected ? DocsColor.textBrand : DocsColor.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.leading, DocsSpacing.spaceBase + CGFloat(depth) * DocsSpacing.spaceBase)
        .padding(.trailing, DocsSpacing.spaceBase)
        .frame(minHeight: DocsSpacing.rowMinHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? DocsColor.brandFillSubtle : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: DocsRadius.sm))
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
