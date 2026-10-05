import SwiftUI

/// A template image keeps a native toolbar action icon-sized. Text glyph labels
/// make the system allocate a wider glass surface even with a circular border.
struct ToolbarIcon: View {
    let icon: MaterialIcon
    var filled: Bool = false

    init(_ icon: MaterialIcon, filled: Bool = false) {
        self.icon = icon
        self.filled = filled
    }

    var body: some View {
        Image(uiImage: icon.uiImage(pointSize: 24, fill: filled) ?? UIImage())
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
    }
}

#Preview("Light") {
    NavigationStack {
        Color.clear.toolbar {
            ToolbarItem {
                Button(action: {}) { ToolbarIcon(.share) }.buttonBorderShape(.circle).accessibilityLabel("Share")
            }
        }
    }
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    NavigationStack {
        Color.clear.toolbar {
            ToolbarItem {
                Button(action: {}) { ToolbarIcon(.share) }.buttonBorderShape(.circle).accessibilityLabel("Share")
            }
        }
    }
    .preferredColorScheme(.dark)
}
