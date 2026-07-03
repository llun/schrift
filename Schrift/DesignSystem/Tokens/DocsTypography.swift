import SwiftUI

struct TypographySpec: Equatable {
    let size: CGFloat
    let weight: Font.Weight
}

enum DocsTypographySpec {
    static let largeTitle = TypographySpec(size: 34, weight: .bold)
    static let title1 = TypographySpec(size: 28, weight: .bold)
    static let title2 = TypographySpec(size: 22, weight: .bold)
    static let headline = TypographySpec(size: 17, weight: .semibold)
    static let body = TypographySpec(size: 17, weight: .regular)
    static let callout = TypographySpec(size: 16, weight: .regular)
    static let subhead = TypographySpec(size: 15, weight: .regular)
    static let footnote = TypographySpec(size: 13, weight: .regular)
    static let caption = TypographySpec(size: 12, weight: .regular)
    static let code = TypographySpec(size: 15, weight: .regular)
}

/// Letter-spacing scale (`--tracking-*`), expressed as an em fraction.
/// Apply with `.tracking(size * DocsTracking.tight)` at a call site.
enum DocsTracking {
    static let tight: CGFloat = -0.02
    static let wide: CGFloat = 0.01
    /// Uppercase screen "eyebrow" section labels (`letter-spacing: 0.05em`).
    static let eyebrow: CGFloat = 0.05
    /// Grouped-list card headers (`letter-spacing: 0.04em`).
    static let groupedHeader: CGFloat = 0.04
}

enum DocsFont {
    static let largeTitle = Font.system(
        size: DocsTypographySpec.largeTitle.size, weight: DocsTypographySpec.largeTitle.weight)
    static let title1 = Font.system(size: DocsTypographySpec.title1.size, weight: DocsTypographySpec.title1.weight)
    static let title2 = Font.system(size: DocsTypographySpec.title2.size, weight: DocsTypographySpec.title2.weight)
    static let headline = Font.system(
        size: DocsTypographySpec.headline.size, weight: DocsTypographySpec.headline.weight)
    static let body = Font.system(size: DocsTypographySpec.body.size, weight: DocsTypographySpec.body.weight)
    static let callout = Font.system(size: DocsTypographySpec.callout.size, weight: DocsTypographySpec.callout.weight)
    static let subhead = Font.system(size: DocsTypographySpec.subhead.size, weight: DocsTypographySpec.subhead.weight)
    static let footnote = Font.system(
        size: DocsTypographySpec.footnote.size, weight: DocsTypographySpec.footnote.weight)
    static let caption = Font.system(size: DocsTypographySpec.caption.size, weight: DocsTypographySpec.caption.weight)
    static let code = Font.system(
        size: DocsTypographySpec.code.size, weight: DocsTypographySpec.code.weight, design: .monospaced)
}
