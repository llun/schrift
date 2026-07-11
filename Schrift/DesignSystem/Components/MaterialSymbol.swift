import SwiftUI

/// Resolves the bundled Material Symbols font. Kept separate from the view so the
/// FILL-axis handling is testable and reused by any UIKit call site.
enum MaterialSymbolFont {
    /// PostScript name of the bundled subset (registered via `UIAppFonts`).
    static let postScriptName = "MaterialSymbolsOutlined-Regular"

    /// The `FILL` variable-font axis identifier — the four-char code `F I L L`.
    /// Setting it to 1 renders the filled variant (selected tab, pinned, emphasis
    /// — matching the handoff's `FILL 1` active state); 0 is the default outline.
    private static let fillAxis = 0x46_49_4C_4C

    static func uiFont(size: CGFloat, fill: Bool) -> UIFont {
        let base = UIFont(name: postScriptName, size: size) ?? .systemFont(ofSize: size)
        guard fill else { return base }
        let descriptor = base.fontDescriptor.addingAttributes([
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [fillAxis: 1]
        ])
        return UIFont(descriptor: descriptor, size: size)
    }
}

extension MaterialIcon {
    /// Renders the glyph to a tintable template `UIImage` for UIKit call sites
    /// (e.g. `UIMenu`/`UIAction` in the block editor's link menu), where a
    /// SwiftUI view can't be used.
    func uiImage(pointSize: CGFloat, fill: Bool = false) -> UIImage? {
        let font = MaterialSymbolFont.uiFont(size: pointSize, fill: fill)
        let attributed = NSAttributedString(
            string: String(character), attributes: [.font: font, .foregroundColor: UIColor.label])
        let size = attributed.size()
        guard size.width > 0, size.height > 0 else { return nil }
        let image = UIGraphicsImageRenderer(size: size).image { _ in attributed.draw(at: .zero) }
        return image.withRenderingMode(.alwaysTemplate)
    }
}

/// Renders a Google Material Symbols glyph from the bundled font — the app's icon
/// system, matching the design handoff exactly. `size` is the point size (as an
/// SF Symbol's `.font(.system(size:))` would be); `fill` switches the FILL axis
/// for active/selected states. Tinted by the enclosing `.foregroundStyle`, like
/// any glyph. Marked `accessibilityHidden` because the glyph is a Private-Use-Area
/// character with no spoken text: meaning is always carried by the enclosing
/// control's `.accessibilityLabel` (icon-only buttons) or adjacent text.
struct MaterialSymbol: View {
    let icon: MaterialIcon
    var size: CGFloat = 24
    var fill: Bool = false

    init(_ icon: MaterialIcon, size: CGFloat = 24, fill: Bool = false) {
        self.icon = icon
        self.size = size
        self.fill = fill
    }

    var body: some View {
        Text(String(icon.character))
            .font(Font(MaterialSymbolFont.uiFont(size: size, fill: fill) as CTFont))
            .accessibilityHidden(true)
    }
}

#Preview {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76))], spacing: 16) {
            ForEach(MaterialIcon.allCases, id: \.self) { icon in
                VStack(spacing: 6) {
                    MaterialSymbol(icon, size: 26)
                        .foregroundStyle(DocsColor.textSecondary)
                    Text(icon.rawValue)
                        .font(.system(size: 8))
                        .foregroundStyle(DocsColor.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
    }
}
