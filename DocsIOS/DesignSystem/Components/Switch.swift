import SwiftUI

struct Switch: View {
    @Binding var isOn: Bool
    var isDisabled: Bool = false

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(DocsColor.brandFill)
            .disabled(isDisabled)
    }
}

#Preview {
    @Previewable @State var isOn = true
    Switch(isOn: $isOn)
        .padding()
}
