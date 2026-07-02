import SwiftUI

enum TextFieldState: Equatable {
    case normal
    case focused
    case error
    case disabled
}

struct TextFieldStyleHex: Equatable {
    let borderHex: UInt32
    let labelHex: UInt32
}

enum TextFieldStyleResolver {
    static func style(state: TextFieldState) -> TextFieldStyleHex {
        switch state {
        case .normal:
            return TextFieldStyleHex(borderHex: DocsColorHex.borderDefault, labelHex: DocsColorHex.textSecondary)
        case .focused:
            return TextFieldStyleHex(borderHex: DocsColorHex.borderFocus, labelHex: DocsColorHex.textBrandSecondary)
        case .error:
            return TextFieldStyleHex(borderHex: DocsColorHex.danger, labelHex: DocsColorHex.danger)
        case .disabled:
            return TextFieldStyleHex(borderHex: DocsColorHex.borderDefault, labelHex: DocsColorHex.textDisabled)
        }
    }
}

struct DocsTextField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var icon: String? = nil
    var helper: String? = nil
    var error: String? = nil
    var isDisabled: Bool = false

    @FocusState private var isFocused: Bool

    private var state: TextFieldState {
        if isDisabled { return .disabled }
        if error != nil { return .error }
        if isFocused { return .focused }
        return .normal
    }

    var body: some View {
        let style = TextFieldStyleResolver.style(state: state)
        VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(hex: style.labelHex))

            HStack(spacing: DocsSpacing.spaceXS) {
                if let icon {
                    Image(systemName: icon)
                        .foregroundStyle(DocsColor.textTertiary)
                }
                TextField(placeholder, text: $text)
                    .font(DocsFont.body)
                    .focused($isFocused)
                    .disabled(isDisabled)
            }
            .padding(DocsSpacing.spaceSM)
            .background(DocsColor.surfacePage)
            .overlay(
                RoundedRectangle(cornerRadius: DocsRadius.sm)
                    .strokeBorder(Color(hex: style.borderHex), lineWidth: state == .focused ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DocsRadius.sm))

            if let error {
                Text(error)
                    .font(DocsFont.caption)
                    .foregroundStyle(DocsColor.danger)
            } else if let helper {
                Text(helper)
                    .font(DocsFont.caption)
                    .foregroundStyle(DocsColor.textTertiary)
            }
        }
    }
}

#Preview {
    @Previewable @State var text = ""
    DocsTextField(label: "Docs server", text: $text, placeholder: "docs.example.org", icon: "cloud", helper: "The app signs in with your existing session.")
        .padding()
}
