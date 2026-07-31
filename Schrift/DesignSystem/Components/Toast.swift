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
    /// - Parameter bottomInset: extra clearance above the bottom edge, for a
    ///   screen that already floats something there. The editor's formatting bar
    ///   lives in a `safeAreaInset` *inside* its canvas, which this overlay sits
    ///   outside of, so without this the toast lands on top of it mid-edit.
    func toast(_ message: Binding<ToastMessage?>, bottomInset: CGFloat = 0) -> some View {
        modifier(ToastPresenter(message: message, bottomInset: bottomInset))
    }
}

private struct ToastPresenter: ViewModifier {
    @Binding var message: ToastMessage?
    let bottomInset: CGFloat

    /// Long enough to read four or five words, short enough not to sit in the
    /// way. The handoff specifies ~2s.
    private static let duration: Duration = .seconds(2)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Toast(message: message.text)
                        .padding(.bottom, DocsSpacing.spaceLG + bottomInset)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(message.id)
                        .animation(.snappy, value: message.id)
                        .task(id: message.id) {
                            // Spoken, not just labelled: the toast dismisses
                            // itself in two seconds and never takes focus, so a
                            // VoiceOver user would otherwise never learn the
                            // copy happened at all. Re-posted per message id, so
                            // a repeated copy is announced again.
                            AccessibilityNotification.Announcement(message.text).post()
                            try? await Task.sleep(for: Self.duration)
                            guard !Task.isCancelled else { return }
                            self.message = nil
                        }
                }
            }
    }
}

#Preview {
    toastPreview
}

#Preview("Dark") {
    toastPreview
        .preferredColorScheme(.dark)
}

@MainActor @ViewBuilder
private var toastPreview: some View {
    // Over content, since the pill is glass and only reads properly against
    // something.
    ZStack {
        VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
            ForEach(0..<14, id: \.self) { _ in
                Text("Document text the toast floats over.")
                    .font(DocsFont.body)
                    .foregroundStyle(DocsColor.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()

        Toast(message: "Link copied")
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, DocsSpacing.spaceLG)
    }
    .background(DocsColor.surfacePage)
}
