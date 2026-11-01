import SwiftUI

/// "Link a page": the `[[` picker, docked above the keyboard as the slash menu's
/// sibling — same glass, same `GlassEffectContainer`, same placement (caret-anchored
/// popovers are unreliable on iOS). It lists the documents matching what was typed
/// after `[[`; choosing one inserts a page chip (`EditorViewModel.selectPageLink`).
struct PageLinkPickerView: View {
    @Environment(\.docsTheme) private var theme
    @Environment(LocalizationStore.self) private var loc
    let picker: PageLinkPickerState
    var onSelect: (Document) -> Void

    /// Four rows at the default text size, scaled so the card still shows about four once
    /// the rows themselves grow — the slash menu's cap.
    @ScaledMetric(relativeTo: .body) private var maxHeight: CGFloat = 4 * DocsSpacing.rowMinHeight
    @ScaledMetric(relativeTo: .body) private var iconTileSize: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(loc[.editor_page_link_title])
                .font(DocsFont.caption)
                .foregroundStyle(theme.colors.textTertiary)
                .padding(.horizontal, DocsSpacing.spaceSM)
                .padding(.top, DocsSpacing.spaceXS)
                .padding(.bottom, DocsSpacing.space3xs)
                .accessibilityAddTraits(.isHeader)
            if picker.matches.isEmpty {
                Text(loc[.editor_page_link_empty])
                    .font(DocsFont.body)
                    .foregroundStyle(theme.colors.textSecondary)
                    .padding(.horizontal, DocsSpacing.spaceSM)
                    .frame(maxWidth: .infinity, minHeight: DocsSpacing.rowMinHeight, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(picker.matches.enumerated()), id: \.element.id) { index, document in
                                row(document, isHighlighted: index == picker.highlightedIndex)
                                    .id(document.id)
                            }
                        }
                    }
                    .frame(maxHeight: maxHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    // A hardware arrow key can move the highlight past the visible rows.
                    .onChange(of: picker.highlighted?.id) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id)
                    }
                }
            }
        }
        .padding(.bottom, DocsSpacing.space3xs)
        .padding(.horizontal, DocsSpacing.space3xs)
        // Glass like the slash menu and the formatting bar it sits directly above; the
        // editor stacks them in one `GlassEffectContainer`.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DocsRadius.lg))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(loc[.editor_page_link_title])
        .onAppear {
            announce(isEmpty: picker.matches.isEmpty, opening: true)
        }
        .onChange(of: picker.matches.isEmpty) { _, isEmpty in
            announce(isEmpty: isEmpty, opening: false)
        }
    }

    private func row(_ document: Document, isHighlighted: Bool) -> some View {
        let title = pageLinkTitle(of: document)
        return Button {
            onSelect(document)
        } label: {
            HStack(spacing: DocsSpacing.spaceSM) {
                MaterialSymbol(.description, size: 18)
                    .foregroundStyle(theme.colors.textBrand)
                    .frame(width: iconTileSize, height: iconTileSize)
                    .background(theme.colors.brandFillSubtle, in: RoundedRectangle(cornerRadius: DocsRadius.md))
                Text(highlightedTitle(title))
                    .font(DocsFont.body)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DocsSpacing.space2xs)
            .padding(.vertical, DocsSpacing.space3xs)
            .frame(minHeight: DocsSpacing.rowMinHeight)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: DocsRadius.md).fill(theme.colors.brandFillSubtle)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    /// The title with the part the query matched in bold, as the mockup shows it.
    private func highlightedTitle(_ title: String) -> AttributedString {
        var attributed = AttributedString(title)
        if let match = pageLinkMatchRange(in: title, query: picker.query),
            let range = Range<AttributedString.Index>(match, in: attributed)
        {
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }

    /// VoiceOver hears the card open ("Link a page") and hears when the query stops
    /// matching anything; the rows themselves are read as the user moves through them.
    private func announce(isEmpty: Bool, opening: Bool) {
        if isEmpty {
            let message =
                opening
                ? loc[.editor_page_link_title] + ", " + loc[.editor_page_link_empty]
                : loc[.editor_page_link_empty]
            AccessibilityNotification.Announcement(message).post()
        } else if opening {
            AccessibilityNotification.Announcement(loc[.editor_page_link_title]).post()
        }
    }
}

/// Shows the picker while the view model has one. Reads `pageLinkPicker` in its own body
/// so a caret move — which can open or close the card — re-renders only this, not the
/// editing surface around it.
struct PageLinkPickerHost: View {
    let viewModel: EditorViewModel

    var body: some View {
        if let picker = viewModel.pageLinkPicker {
            PageLinkPickerView(picker: picker, onSelect: { viewModel.selectPageLink($0) })
        }
    }
}

#Preview {
    pageLinkPickerPreview
}

/// Glass is only legible over something, so the preview floats the card over
/// document-like text, as the slash menu's does.
#Preview("Dark") {
    pageLinkPickerPreview
        .preferredColorScheme(.dark)
}

@MainActor @ViewBuilder
private var pageLinkPickerPreview: some View {
    let documents = ["Schrift release checklist", "Release notes 1.4", "TestFlight releases"].map { title in
        Document(
            id: UUID(), title: title, excerpt: nil, abilities: DocumentAbilities(), linkReach: .restricted,
            linkRole: .reader, isFavorite: false, depth: 1, numchild: 0, path: "0001",
            createdAt: Date(), updatedAt: Date(), userRole: nil, creator: nil)
    }
    ZStack(alignment: .bottom) {
        VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
            ForEach(0..<12, id: \.self) { _ in
                Text("Body text the picker floats over, to check legibility.")
                    .font(DocsFont.body)
                    .foregroundStyle(DocsColor.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()

        VStack {
            PageLinkPickerView(
                picker: PageLinkPickerState(query: "rel", matches: documents, highlightedIndex: 0), onSelect: { _ in })
            PageLinkPickerView(
                picker: PageLinkPickerState(query: "zzz", matches: [], highlightedIndex: 0), onSelect: { _ in })
        }
        .padding()
    }
    .background(DocsColor.surfacePage)
    .environment(LocalizationStore())
}
