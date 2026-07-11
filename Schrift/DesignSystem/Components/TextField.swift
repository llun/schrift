import SwiftUI

enum TextFieldState: Equatable {
    case normal
    case focused
    case error
    case disabled
}

struct TextFieldStyleHex: Equatable {
    let borderLightHex: UInt32
    let borderDarkHex: UInt32
    let labelLightHex: UInt32
    let labelDarkHex: UInt32
}

enum TextFieldStyleResolver {
    static func style(state: TextFieldState) -> TextFieldStyleHex {
        // The label stays a constant neutral gray in every state (reference);
        // only the border (and the focus ring) convey focus/error. Disabled
        // dims the label to preserve the sunk look.
        switch state {
        case .normal:
            return TextFieldStyleHex(
                borderLightHex: DocsColorHex.borderDefault, borderDarkHex: DocsColorHexDark.borderDefault,
                labelLightHex: DocsColorHex.textSecondary, labelDarkHex: DocsColorHexDark.textSecondary)
        case .focused:
            // Reference focused border is --border-brand (#5E5CD0 == brandFill); --border-focus is the soft ring.
            return TextFieldStyleHex(
                borderLightHex: DocsColorHex.brandFill, borderDarkHex: DocsColorHexDark.brandFill,
                labelLightHex: DocsColorHex.textSecondary, labelDarkHex: DocsColorHexDark.textSecondary)
        case .error:
            return TextFieldStyleHex(
                borderLightHex: DocsColorHex.danger, borderDarkHex: DocsColorHexDark.danger,
                labelLightHex: DocsColorHex.textSecondary, labelDarkHex: DocsColorHexDark.textSecondary)
        case .disabled:
            return TextFieldStyleHex(
                borderLightHex: DocsColorHex.borderDefault, borderDarkHex: DocsColorHexDark.borderDefault,
                labelLightHex: DocsColorHex.textDisabled, labelDarkHex: DocsColorHexDark.textDisabled)
        }
    }
}

struct DocsTextField: View {
    var label: String? = nil
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
        VStack(alignment: .leading, spacing: DocsSpacing.space2xs) {
            if let label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(lightHex: style.labelLightHex, darkHex: style.labelDarkHex))
            }

            HStack(spacing: DocsSpacing.spaceXS) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundStyle(DocsColor.textTertiary)
                }
                TextField(placeholder, text: $text)
                    .font(DocsFont.callout)
                    .focused($isFocused)
                    .disabled(isDisabled)
            }
            .padding(.horizontal, DocsSpacing.spaceSM)
            .frame(height: 40)
            // Disabled fields sink to the sunken surface (reference); enabled stay white.
            .background(isDisabled ? DocsColor.surfaceSunken : DocsColor.surfacePage)
            .clipShape(RoundedRectangle(cornerRadius: DocsRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: DocsRadius.sm)
                    .strokeBorder(Color(lightHex: style.borderLightHex, darkHex: style.borderDarkHex), lineWidth: 1)
            )
            // Soft brand-400 focus ring sitting just outside the field, matching
            // the reference's 3px glow.
            .overlay(
                RoundedRectangle(cornerRadius: DocsRadius.sm)
                    .inset(by: -1.5)
                    .stroke(DocsColor.borderFocus.opacity(0.25), lineWidth: state == .focused ? 3 : 0)
            )
            .opacity(isDisabled ? 0.6 : 1)

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
    DocsTextField(
        label: "Docs server", text: $text, placeholder: "docs.example.org", icon: "cloud",
        helper: "The app signs in with your existing session."
    )
    .padding()
}
