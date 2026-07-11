import SwiftUI

/// The appearance options offered by the picker, in display order — light,
/// dark, then system (matches the handoff).
func appearanceOptions() -> [AppAppearance] {
    [.light, .dark, .system]
}

/// Maps an `AppAppearance` to the `L10nKey` for its display label. Shared by
/// the Profile row's current-value text and this sheet's option rows.
func appearanceValueKey(_ appearance: AppAppearance) -> L10nKey {
    switch appearance {
    case .system: .appearance_system
    case .light: .appearance_light
    case .dark: .appearance_dark
    }
}

/// A bottom sheet listing the three appearance options; tapping one writes it
/// to `AppearanceStore` and dismisses. Presented by `ProfileScreen` with a
/// fitted `.presentationDetents([.height(280)])`.
struct AppearancePickerSheet: View {
    @Environment(AppearanceStore.self) private var store
    @Environment(LocalizationStore.self) private var loc
    @Environment(\.dismiss) private var dismiss

    private let options = appearanceOptions()

    var body: some View {
        // Shared `SheetHeader` (handoff), then — unlike the flat Language picker —
        // the short three-option list keeps its boxed card below (matching the
        // handoff's Appearance sheet).
        VStack(spacing: 0) {
            SheetHeader(title: loc[.profile_appearance], closeLabel: loc[.common_close], onClose: { dismiss() })

            VStack(spacing: 0) {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    Button {
                        store.selected = option
                        dismiss()
                    } label: {
                        ProfileTrailingRow(icon: option.icon, title: loc[appearanceValueKey(option)]) {
                            if option == store.selected {
                                MaterialSymbol(.check, size: 17)
                                    .foregroundStyle(DocsColor.brandFill)
                                    // The glyph carries no meaning to VoiceOver; the
                                    // row's .isSelected trait announces the state.
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option == store.selected ? .isSelected : [])
                }
            }
            .background(DocsColor.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DocsRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: DocsRadius.lg)
                    .strokeBorder(DocsColor.borderDefault, lineWidth: 1)
            )
            .padding(.horizontal, DocsSpacing.gutter)

            Spacer(minLength: 0)
        }
        .padding(.bottom, DocsSpacing.spaceSM)
        // White page surface (like the restyled Profile), so the option card is
        // defined by its hairline border rather than a sunken grey backdrop.
        .background(DocsColor.surfacePage)
    }
}

#Preview {
    AppearancePickerSheet()
        .environment(AppearanceStore())
        .environment(LocalizationStore())
}
