import SwiftUI

func themeValueKey(_ theme: AppTheme) -> L10nKey {
    switch theme {
    case .white: .theme_white
    case .mist: .theme_mist
    case .paper: .theme_paper
    }
}

func themeDescriptionKey(_ theme: AppTheme) -> L10nKey {
    switch theme {
    case .white: .theme_white_description
    case .mist: .theme_mist_description
    case .paper: .theme_paper_description
    }
}

/// Changes only the local palette. Keeping the sheet open makes choices comparable
/// and preserves presentation identity while the entire app repaints underneath it.
struct ThemePickerSheet: View {
    @Environment(ThemeStore.self) private var store
    @Environment(LocalizationStore.self) private var loc
    @Environment(\.docsTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: loc[.profile_theme], closeLabel: loc[.common_close], onClose: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: DocsSpacing.spaceSM) {
                    ForEach(AppTheme.allCases, id: \.self) { option in
                        Button {
                            store.selected = option
                        } label: {
                            HStack(spacing: DocsSpacing.spaceBase) {
                                ThemeSwatch(theme: option)
                                VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
                                    Text(loc[themeValueKey(option)])
                                        .font(DocsFont.body.weight(.semibold))
                                        .foregroundStyle(theme.colors.textPrimary)
                                    Text(loc[themeDescriptionKey(option)])
                                        .font(DocsFont.footnote)
                                        .foregroundStyle(theme.colors.textSecondary)
                                }
                                Spacer(minLength: 0)
                                MaterialSymbol(.check, size: 20)
                                    .foregroundStyle(theme.colors.textBrand)
                                    .opacity(store.selected == option ? 1 : 0)
                                    .accessibilityHidden(true)
                            }
                            .padding(.vertical, DocsSpacing.spaceXS)
                            .frame(minHeight: DocsSpacing.rowMinHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(store.selected == option ? .isSelected : [])
                        .accessibilityIdentifier("theme.\(option.rawValue)")
                    }
                    Text(loc[.theme_footer])
                        .font(DocsFont.footnote)
                        .foregroundStyle(theme.colors.textSecondary)
                        .padding(.top, DocsSpacing.spaceXS)
                }
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.bottom, DocsSpacing.spaceMD)
            }
        }
        .background(theme.colors.surfacePage)
        .presentationBackground(theme.colors.surfacePage)
    }
}

/// Shows a paired light/dark sample without overriding the surrounding appearance.
struct ThemeSwatch: View {
    let theme: AppTheme

    var body: some View {
        HStack(spacing: 0) {
            sample(isDark: false)
            sample(isDark: true)
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: DocsRadius.md))
        .overlay(RoundedRectangle(cornerRadius: DocsRadius.md).strokeBorder(theme.colors.borderStrong, lineWidth: 1))
        .accessibilityHidden(true)
    }

    private func sample(isDark: Bool) -> some View {
        let palette = DocsPalette(theme: theme, isDark: isDark)
        return VStack(alignment: .leading, spacing: DocsSpacing.space2xs) {
            Text("Aa")
                .font(DocsFont.caption.weight(.semibold))
            Rectangle().frame(height: 2)
            Rectangle().frame(height: 2).opacity(0.5)
        }
        .foregroundStyle(Color(hex: palette.textPrimary))
        .padding(DocsSpacing.space2xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: palette.surfacePage))
    }
}

private struct ThemePickerPreview: View {
    @State private var store = ThemeStore(userDefaults: UserDefaults(suiteName: "ThemePickerPreview.\(UUID())")!)
    private let loc = LocalizationStore(
        userDefaults: UserDefaults(suiteName: "ThemePickerLocalizationPreview.\(UUID())")!)

    var body: some View {
        ThemePickerSheet()
            .environment(store)
            .environment(loc)
            .environment(\.docsTheme, store.selected)
    }
}

#Preview { ThemePickerPreview() }
