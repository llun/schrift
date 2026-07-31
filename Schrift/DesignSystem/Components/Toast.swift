import SwiftUI

/// A transient confirmation that something happened — "Link copied" and the
/// like.
///
/// One of the handoff's four feedback registers, and the narrowest: a toast
/// only ever *confirms*, never asks or warns. Anything the user must act on is
/// an alert, anything persistent is a callout or a banner. It carries no
/// button, because a message you must dismiss is not transient.
///
/// Presented with `.toast(_:)` rather than constructed directly.
struct Toast: View {
    let message: String

    var body: some View {
        Text(message)
            .font(DocsFont.footnote.weight(.semibold))
            .foregroundStyle(DocsColor.textPrimary)
            .padding(.horizontal, DocsSpacing.spaceBase)
            .padding(.vertical, DocsSpacing.spaceSM)
            // Floats over content, so it is glass — same rule as the editor's
            // formatting bar.
            .glassEffect(.regular, in: Capsule())
            .accessibilityAddTraits(.isStaticText)
    }
}

/// What a screen shows in its toast slot. `nil` means nothing is showing.
///
/// Carries an `id` so re-copying the *same* text still re-triggers the
/// presentation — without it, setting an identical message would look like no
/// change at all and the toast would never reappear.
struct ToastMessage: Equatable, Identifiable {
    let id = UUID()
    let text: String

    init(_ text: String) {
        self.text = text
    }
}

extension View {
    /// Presents a toast above this view, auto-dismissing after a moment.
    ///
    /// The binding is cleared by the timer, so a caller only ever *sets* it —
    /// no dismissal bookkeeping at the call site.
    func toast(_ message: Binding<ToastMessage?>) -> some View {
        modifier(ToastPresenter(message: message))
    }
}

private struct ToastPresenter: ViewModifier {
    @Binding var message: ToastMessage?

    /// Long enough to read four or five words, short enough not to sit in the
    /// way. The handoff specifies ~2s.
    private static let duration: Duration = .seconds(2)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Toast(message: message.text)
                        .padding(.bottom, DocsSpacing.spaceLG)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        // Re-announced per message id, so a repeated copy is
                        // spoken again rather than silently ignored.
                        .id(message.id)
                        .task(id: message.id) {
                            try? await Task.sleep(for: Self.duration)
                            guard !Task.isCancelled else { return }
                            self.message = nil
                        }
                }
            }
            .animation(.snappy, value: message?.id)
    }
}

#Preview {
    @Previewable @State var message: ToastMessage? = ToastMessage("Link copied")

    VStack {
        Button("Show toast") { message = ToastMessage("Link copied") }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(DocsColor.surfacePage)
    .toast($message)
}
