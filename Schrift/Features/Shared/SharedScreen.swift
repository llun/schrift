import SwiftUI

private func reachLabel(_ reach: LinkReach) -> String {
    switch reach {
    case .restricted: return "Restricted"
    case .authenticated: return "Connected"
    case .public: return "Public"
    }
}

struct SharedScreen: View {
    @Bindable var viewModel: SharedViewModel
    let serverHost: String
    var onOpenDocument: (Document) -> Void

    @AppStorage("schrift.workOffline") private var workOffline = false

    private var scopeIndex: Binding<Int> {
        Binding(
            get: { viewModel.scope == .withMe ? 0 : 1 },
            set: { viewModel.scope = $0 == 0 ? .withMe : .byMe }
        )
    }

    private func subtitle(for document: Document) -> String {
        switch viewModel.scope {
        case .withMe:
            return "Shared · \(documentRowDate(document))"
        case .byMe:
            return "\(reachLabel(document.linkReach)) · Shared \(documentRowDate(document))"
        }
    }

    private var footerText: String {
        switch viewModel.scope {
        case .withMe:
            return "Documents other people have invited you to. Your access depends on your role on each one."
        case .byMe:
            return "Documents you own or have shared. Manage who can see them from each document's share sheet."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "Shared", subtitle: serverHost, largeTitle: true)

            if workOffline { OfflineBanner() }

            ScrollView {
                VStack(alignment: .leading, spacing: DocsSpacing.spaceBase) {
                    SegmentedControl(
                        segments: ["Shared with me", "Shared by me"],
                        selectedIndex: scopeIndex
                    )
                    .padding(.horizontal, DocsSpacing.gutter)
                    // 18pt gap below the control, matching Home/Search and the reference.
                    .padding(.bottom, DocsSpacing.space4xs)

                    ListSection(header: "\(viewModel.documents.count) documents") {
                        ForEach(Array(viewModel.documents.enumerated()), id: \.element.id) { index, document in
                            if index > 0 {
                                ProfileRowDivider()
                            }
                            SharedRow(
                                title: document.title ?? "Untitled document",
                                subtitle: subtitle(for: document),
                                onTap: { onOpenDocument(document) }
                            )
                        }
                    }
                    .padding(.horizontal, DocsSpacing.gutter)

                    Text(footerText)
                        .font(DocsFont.footnote)
                        .foregroundStyle(DocsColor.textTertiary)
                        .padding(.horizontal, DocsSpacing.gutterGrouped)
                }
                .padding(.top, DocsSpacing.space3xs)
                .padding(.bottom, DocsSpacing.spaceBase)
            }
        }
        .background(DocsColor.surfacePage)
        .task {
            await viewModel.load()
        }
    }
}

#Preview {
    SharedScreen(
        viewModel: SharedViewModel(client: DocsAPIClient(baseURL: URL(string: "https://docs.llun.dev/api/v1.0/")!)),
        serverHost: "docs.llun.dev",
        onOpenDocument: { _ in }
    )
}
