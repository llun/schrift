import SwiftUI

/// Every file attached to a document this device has cached, grouped by
/// document. Pushed from Profile.
///
/// The rows are the editor's own `AttachmentCardView`, so a file downloads,
/// previews and fails exactly as it does inside its document, sharing the one
/// app-scoped `AttachmentLoader` cache. The stack is lazy so a long list only
/// asks for the cards on screen.
struct AttachmentsScreen: View {
    @Environment(\.docsTheme) private var theme
    @Environment(LocalizationStore.self) private var loc
    @Bindable var viewModel: AttachmentsViewModel
    var isOffline: Bool = false

    var body: some View {
        Group {
            if viewModel.hasLoaded && viewModel.groups.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text(loc[.attachments_empty_title])
                    } icon: {
                        MaterialSymbol(.description, size: 44)
                    }
                } description: {
                    Text(loc[.attachments_empty_body])
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DocsSpacing.spaceLG) {
                        ForEach(viewModel.groups) { group in
                            ListSection(header: group.title ?? loc[.common_untitled]) {
                                ForEach(group.attachments, id: \.urlString) { display in
                                    AttachmentCardView(display: display, isOffline: isOffline)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, DocsSpacing.space3xs)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, DocsSpacing.gutter)
                    .padding(.top, DocsSpacing.space3xs)
                    .padding(.bottom, DocsSpacing.spaceMD)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.colors.surfacePage)
        .navigationTitle(loc[.profile_attachments])
        .navigationBarTitleDisplayMode(.inline)
        // Re-read on every appearance: documents opened since the last visit
        // add to the cache, and the read is local and cheap.
        .onAppear { viewModel.load() }
    }
}

#Preview {
    NavigationStack {
        AttachmentsScreen(viewModel: AttachmentsViewModel(serverOrigin: "https://docs.llun.dev"))
    }
    .environment(LocalizationStore())
    .environment(AttachmentLoader.inert())
}
