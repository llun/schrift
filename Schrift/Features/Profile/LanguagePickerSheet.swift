import SwiftUI

/// A bottom sheet listing every `AppLanguage` by autonym; tapping one writes
/// it to `LocalizationStore` and dismisses, live-switching the whole app.
/// Presented by `ProfileScreen` with `.presentationDetents([.medium, .large])`.
struct LanguagePickerSheet: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DocsSpacing.space2xs) {
            Text(loc[.profile_language])
                .font(DocsFont.headline)
                .foregroundStyle(DocsColor.textPrimary)
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.top, DocsSpacing.spaceSM)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(AppLanguage.allCases) { language in
                        Button {
                            loc.language = language
                            dismiss()
                        } label: {
                            ProfileTrailingRow(title: language.autonym) {
                                if language == loc.language {
                                    Image(systemName: "checkmark")
                                        .font(DocsFont.body)
                                        .foregroundStyle(DocsColor.brandFill)
                                        // The glyph carries no meaning to VoiceOver; the
                                        // row's .isSelected trait announces the state.
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(language == loc.language ? .isSelected : [])
                    }
                }
                .background(DocsColor.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: DocsRadius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: DocsRadius.lg)
                        .strokeBorder(DocsColor.borderDefault, lineWidth: 1)
                )
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.bottom, DocsSpacing.spaceSM)
            }
        }
        .background(DocsColor.surfaceSunken)
    }
}

#Preview {
    LanguagePickerSheet()
        .environment(LocalizationStore())
}
