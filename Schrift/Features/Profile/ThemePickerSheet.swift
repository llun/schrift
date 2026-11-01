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

/// Relative widths of the specimen's two placeholder text lines (full, then shorter).
let themeSpecimenLineFractions: [CGFloat] = [1, 0.62]

/// The specimen's fixed width beside the name, or `nil` when stacked above it: the scaled width
/// grows past a phone's row at AX4/AX5, so a stacked specimen fills the row instead.
func themeSpecimenFixedWidth(scaledWidth: CGFloat, stacked: Bool) -> CGFloat? {
    stacked ? nil : scaledWidth
}

/// Changes only the local palette. Keeping the sheet open makes choices comparable
/// and preserves presentation identity while the entire app repaints underneath it.
struct ThemePickerSheet: View {
    @Environment(ThemeStore.self) private var store
    @Environment(LocalizationStore.self) private var loc
    @Environment(\.docsTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: loc[.profile_theme], closeLabel: loc[.common_close], onClose: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: DocsSpacing.spaceSM) {
                    ForEach(AppTheme.allCases, id: \.self) { option in
                        Button {
                            store.selected = option
                        } label: {
                            let isSelected = store.selected == option
                            let specimen = ThemeSpecimen(
                                theme: option,
                                title: loc[.theme_specimen_title],
                                chipTitle: loc[.theme_specimen_chip],
                                isSelected: isSelected,
                                stacked: rowUsesStackedLayout(typeSize))
                            let name = VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
                                Text(loc[themeValueKey(option)])
                                    .font(DocsFont.body.weight(.semibold))
                                    .foregroundStyle(theme.colors.textPrimary)
                                Text(loc[themeDescriptionKey(option)])
                                    .font(DocsFont.footnote)
                                    .foregroundStyle(theme.colors.textSecondary)
                            }
                            let check = MaterialSymbol(.check, size: 20)
                                .foregroundStyle(theme.colors.textBrand)
                                .opacity(isSelected ? 1 : 0)
                                .accessibilityHidden(true)
                            Group {
                                if rowUsesStackedLayout(typeSize) {
                                    VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
                                        specimen
                                        HStack(alignment: .top, spacing: DocsSpacing.spaceBase) {
                                            name
                                            Spacer(minLength: 0)
                                            check
                                        }
                                    }
                                } else {
                                    HStack(spacing: DocsSpacing.spaceBase) {
                                        specimen
                                        name
                                        Spacer(minLength: 0)
                                        check
                                    }
                                }
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

/// A small document drawn through `theme`'s own palette in the surrounding light/dark appearance:
/// a bold title, two placeholder lines and a page chip mirroring `DocumentLinkChip`. Decorative —
/// the option button carries the name and selected trait.
struct ThemeSpecimen: View {
    let theme: AppTheme
    let title: String
    let chipTitle: String
    var isSelected = false
    /// True when the specimen sits above the name; it then fills the row instead of keeping a fixed width.
    var stacked = false

    @ScaledMetric(relativeTo: .caption) private var width: CGFloat = 124

    var body: some View {
        let colors = theme.colors
        let fixedWidth = themeSpecimenFixedWidth(scaledWidth: width, stacked: stacked)
        VStack(alignment: .leading, spacing: DocsSpacing.space2xs) {
            Text(title)
                .font(DocsFont.caption.weight(.bold))
                .foregroundStyle(colors.textPrimary)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: DocsSpacing.space3xs) {
                ForEach(Array(themeSpecimenLineFractions.enumerated()), id: \.offset) { _, fraction in
                    SpecimenLine(fraction: fraction, color: colors.textPrimary.opacity(0.35))
                }
            }
            HStack(spacing: DocsSpacing.space4xs) {
                MaterialSymbol(.description, size: 11, relativeTo: .caption)
                Text(chipTitle)
                    .font(DocsFont.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(colors.textBrand)
            .padding(.horizontal, DocsSpacing.space3xs)
            .padding(.vertical, DocsSpacing.space4xs)
            .background(colors.brandFillSubtle, in: RoundedRectangle(cornerRadius: DocsRadius.sm))
        }
        .padding(DocsSpacing.spaceXS)
        .frame(
            minWidth: fixedWidth, maxWidth: fixedWidth ?? .infinity, alignment: .leading
        )
        .background(colors.surfacePage, in: RoundedRectangle(cornerRadius: DocsRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: DocsRadius.lg)
                .strokeBorder(isSelected ? colors.brandFill : colors.borderStrong, lineWidth: isSelected ? 2 : 1)
        )
        .accessibilityHidden(true)
    }
}

private struct SpecimenLine: View {
    let fraction: CGFloat
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(color).frame(width: proxy.size.width * fraction)
        }
        .frame(height: 5)
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
