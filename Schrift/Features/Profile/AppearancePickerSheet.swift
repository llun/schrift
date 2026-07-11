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
        VStack(alignment: .leading, spacing: DocsSpacing.space2xs) {
            Text(loc[.profile_appearance])
                .font(DocsFont.headline)
                .foregroundStyle(DocsColor.textPrimary)
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.top, DocsSpacing.spaceSM)

            VStack(spacing: 0) {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    if index > 0 {
                        ProfileRowDivider()
                    }
                    Button {
                        store.selected = option
                        dismiss()
                    } label: {
                        ProfileTrailingRow(systemImage: option.iconName, title: loc[appearanceValueKey(option)]) {
                            if option == store.selected {
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

            Spacer(minLength: 0)
        }
        .padding(.bottom, DocsSpacing.spaceSM)
        .background(DocsColor.surfaceSunken)
    }
}

#Preview {
    AppearancePickerSheet()
        .environment(AppearanceStore())
        .environment(LocalizationStore())
}
