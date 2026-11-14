import SwiftUI

/// The `@` mention picker, docked above the keyboard alongside the formatting
/// bar — same Liquid Glass treatment and `GlassEffectContainer` placement as
/// `PageLinkPickerView` and `SlashMenuView`.
struct NativeMentionPickerView: View {
    @Environment(\.docsTheme) private var theme
    @Environment(LocalizationStore.self) private var loc
    let picker: NativeMentionPickerState
    var onSelect: (MentionCandidate) -> Void

    @ScaledMetric(relativeTo: .body) private var maxHeight: CGFloat = 4 * DocsSpacing.rowMinHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(loc[.editor_mention_title])
                .font(DocsFont.caption)
                .foregroundStyle(theme.colors.textTertiary)
                .padding(.horizontal, DocsSpacing.spaceSM)
                .padding(.top, DocsSpacing.spaceXS)
                .padding(.bottom, DocsSpacing.space3xs)
                .accessibilityAddTraits(.isHeader)

            if picker.isLoading {
                HStack(spacing: DocsSpacing.spaceSM) {
                    ProgressView()
                        .controlSize(.small)
                    Text(loc[.editor_mention_loading])
                        .font(DocsFont.body)
                        .foregroundStyle(theme.colors.textSecondary)
                }
                .padding(.horizontal, DocsSpacing.spaceSM)
                .frame(maxWidth: .infinity, minHeight: DocsSpacing.rowMinHeight, alignment: .leading)
                .accessibilityIdentifier("editor.mentionPicker.loading")
            } else if picker.matches.isEmpty {
                Text(loc[.editor_mention_empty])
                    .font(DocsFont.body)
                    .foregroundStyle(theme.colors.textSecondary)
                    .padding(.horizontal, DocsSpacing.spaceSM)
                    .frame(maxWidth: .infinity, minHeight: DocsSpacing.rowMinHeight, alignment: .leading)
                    .accessibilityIdentifier("editor.mentionPicker.empty")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(picker.matches.enumerated()), id: \.element.id) { index, candidate in
                                row(candidate, isHighlighted: index == picker.highlightedIndex)
                                    .id(candidate.id)
                            }
                        }
                    }
                    .frame(maxHeight: maxHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: picker.highlighted?.id) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id)
                    }
                }
            }
        }
        .padding(.bottom, DocsSpacing.space3xs)
        .padding(.horizontal, DocsSpacing.space3xs)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DocsRadius.lg))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(loc[.editor_mention_title])
        .accessibilityIdentifier("editor.mentionPicker")
        .onAppear {
            announce(isLoading: picker.isLoading, isEmpty: picker.matches.isEmpty, opening: true)
        }
        .onChange(of: picker.isLoading) { wasLoading, isLoading in
            if wasLoading && !isLoading {
                announce(isLoading: false, isEmpty: picker.matches.isEmpty, opening: false)
            }
        }
        .onChange(of: picker.matches.isEmpty) { _, isEmpty in
            if !picker.isLoading {
                announce(isLoading: false, isEmpty: isEmpty, opening: false)
            }
        }
    }

    private func row(_ candidate: MentionCandidate, isHighlighted: Bool) -> some View {
        let displayName = NativeInlineObject.clippedNonEmptyDisplayText(candidate.fullName) ?? ""
        let displayEmail = NativeInlineObject.clippedNonEmptyDisplayText(candidate.email)
        return Button {
            onSelect(candidate)
        } label: {
            HStack(spacing: DocsSpacing.spaceSM) {
                Avatar(name: displayName, size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(highlightedName(displayName))
                        .font(DocsFont.body)
                        .foregroundStyle(theme.colors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let email = displayEmail, email != displayName {
                        Text(email)
                            .font(DocsFont.caption)
                            .foregroundStyle(theme.colors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
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
        .accessibilityLabel(Self.rowAccessibilityLabel(name: displayName, email: displayEmail))
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityIdentifier("editor.mentionPicker.row.\(candidate.userID)")
    }

    static func rowAccessibilityLabel(for candidate: MentionCandidate) -> String {
        let displayName = NativeInlineObject.clippedNonEmptyDisplayText(candidate.fullName) ?? ""
        let displayEmail = NativeInlineObject.clippedNonEmptyDisplayText(candidate.email)
        return rowAccessibilityLabel(name: displayName, email: displayEmail)
    }

    private static func rowAccessibilityLabel(name: String, email: String?) -> String {
        if let email, email != name {
            return "\(name), \(email)"
        }
        return name
    }

    private func highlightedName(_ name: String) -> AttributedString {
        var attributed = AttributedString(name)
        if let match = mentionMatchRange(in: name, query: picker.query),
            let range = Range<AttributedString.Index>(match, in: attributed)
        {
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }

    private func announce(isLoading: Bool, isEmpty: Bool, opening: Bool) {
        if isLoading {
            if opening {
                AccessibilityNotification.Announcement(
                    loc[.editor_mention_title] + ", " + loc[.editor_mention_loading]
                ).post()
            }
        } else if isEmpty {
            let message =
                opening
                ? loc[.editor_mention_title] + ", " + loc[.editor_mention_empty]
                : loc[.editor_mention_empty]
            AccessibilityNotification.Announcement(message).post()
        } else if opening {
            AccessibilityNotification.Announcement(loc[.editor_mention_title]).post()
        }
    }
}

/// Renders whichever native inline picker (`PageLinkPickerView` or
/// `NativeMentionPickerView`) is active for `presentation`.
struct NativeInlinePickerCard: View {
    let presentation: NativeInlinePickerPresentation
    let input: NativeInputCoordinator

    var body: some View {
        switch presentation {
        case .pageLink(let state):
            PageLinkPickerView(picker: state) { document in
                input.selectPageLink(document)
            }
        case .mention(let state):
            NativeMentionPickerView(picker: state) { candidate in
                input.selectMention(candidate)
            }
        }
    }
}

/// Reads `input.inlinePicker` in its own body so caret moves only re-render the
/// floating picker card rather than the surrounding native editor view.
struct NativeInlinePickerHost: View {
    let input: NativeInputCoordinator

    var body: some View {
        if let presentation = input.inlinePicker {
            NativeInlinePickerCard(presentation: presentation, input: input)
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.bottom, DocsSpacing.space2xs)
        }
    }
}

#Preview {
    mentionPickerPreview
}

#Preview("Dark") {
    mentionPickerPreview
        .preferredColorScheme(.dark)
}

@MainActor @ViewBuilder
private var mentionPickerPreview: some View {
    let candidates = [
        MentionCandidate(
            userID: "11111111-1111-4111-8111-111111111111",
            fullName: "Ada Lovelace", shortName: "Ada", email: "ada@example.org"),
        MentionCandidate(
            userID: "22222222-2222-4222-8222-222222222222",
            fullName: "Grace Hopper", shortName: "Grace", email: "grace@example.org"),
    ]
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
            NativeMentionPickerView(
                picker: NativeMentionPickerState(
                    query: "ada", isLoading: false, matches: candidates, highlightedIndex: 0),
                onSelect: { _ in })
            NativeMentionPickerView(
                picker: NativeMentionPickerState(query: "", isLoading: true, matches: [], highlightedIndex: 0),
                onSelect: { _ in })
            NativeMentionPickerView(
                picker: NativeMentionPickerState(query: "zzz", isLoading: false, matches: [], highlightedIndex: 0),
                onSelect: { _ in })
        }
        .padding()
    }
    .background(DocsColor.surfacePage)
    .environment(LocalizationStore())
}
