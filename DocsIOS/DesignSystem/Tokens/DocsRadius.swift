import CoreGraphics

enum DocsRadius {
    static let xs: CGFloat = 2
    static let sm: CGFloat = 4
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let xl2: CGFloat = 24
    /// Use `Capsule()`/`Circle()` shapes for true pill/circular corners rather than this value directly.
    static let pill: CGFloat = 999
}
