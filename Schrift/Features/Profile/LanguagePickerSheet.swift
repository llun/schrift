import SwiftUI

/// A bottom sheet listing every `AppLanguage` by autonym; tapping one writes
/// it to `LocalizationStore` and dismisses, live-switching the whole app.
/// Presented by `ProfileScreen` with `.presentationDetents([.medium, .large])`.
struct LanguagePickerSheet: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // A flat, boxless list under the shared `SheetHeader` (handoff): the long,
        // scrollable language list reads cleaner without the card/border/dividers
        // the shorter Appearance picker keeps.
        VStack(spacing: 0) {
            SheetHeader(title: loc[.profile_language], closeLabel: loc[.common_close], onClose: { dismiss() })

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(AppLanguage.allCases) { language in
                        Button {
                            loc.language = language
                            dismiss()
                        } label: {
                            ProfileTrailingRow(title: language.autonym) {
                                if language == loc.language {
                                    MaterialSymbol(.check, size: 17)
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
                .padding(.bottom, DocsSpacing.spaceSM)
            }
        }
        // White page surface (like the restyled Profile), matching the handoff.
        .background(DocsColor.surfacePage)
    }
}

#Preview {
    LanguagePickerSheet()
        .environment(LocalizationStore())
}
