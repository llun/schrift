import CoreGraphics

enum DocsSpacing {
    // Design scale (4px base unit)
    static let space4xs: CGFloat = 2
    static let space3xs: CGFloat = 4
    static let space2xs: CGFloat = 6
    static let spaceXS: CGFloat = 8
    static let spaceSM: CGFloat = 12
    static let spaceBase: CGFloat = 16
    static let spaceMD: CGFloat = 24
    static let spaceLG: CGFloat = 32
    static let spaceXL: CGFloat = 40
    static let space2XL: CGFloat = 48
    static let space3XL: CGFloat = 56
    static let space4XL: CGFloat = 64
    static let space5XL: CGFloat = 72

    // iOS layout constants. The bar heights that used to live here went with the
    // chrome that needed them: the app draws no bars of its own now, and the
    // system's own metrics are not ours to hardcode — `tabBarHeight = 49` was
    // the opaque pre-iOS-26 bar, nothing like the floating capsule shipped today.
    static let rowMinHeight: CGFloat = 44
    static let gutter: CGFloat = 16
    static let gutterGrouped: CGFloat = 20
}
