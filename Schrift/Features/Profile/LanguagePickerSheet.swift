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
                    ForEach(Array(AppLanguage.allCases.enumerated()), id: \.element) { index, language in
                        if index > 0 {
                            ProfileRowDivider()
                        }
                        Button {
                            loc.language = language
                            dismiss()
                        } label: {
                            ProfileTrailingRow(title: language.autonym) {
                                if language == loc.language {
                                    Image(systemName: "checkmark")
                                        .font(DocsFont.body)
                                        .foregroundStyle(DocsColor.brandFill)
                                }
                            }
                        }
                        .buttonStyle(.plain)
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
