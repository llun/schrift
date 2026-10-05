import SwiftUI

struct Switch: View {
    @Environment(\.docsTheme) private var theme
    @Binding var isOn: Bool
    var isDisabled: Bool = false

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(theme.colors.brandFill)
            .disabled(isDisabled)
    }
}

#Preview {
    @Previewable @State var isOn = true
    Switch(isOn: $isOn)
        .padding()
}
