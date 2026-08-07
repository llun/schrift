import SwiftUI

/// A photo queued on this device, rendered from the bytes on disk.
///
/// Never issues a request — the whole point of a queued photo is that it cannot be fetched yet.
/// It is branched in *ahead* of `MarkdownImageView`, so `imageLoadPolicy`'s fail-closed
/// tap-to-load card (which a placeholder URL would otherwise land on, since a custom scheme can
/// never match an http(s) server origin) is never reached for one of these.
///
/// The `.missing` state is an affordance as much as a state. A placeholder whose record or bytes
/// are gone still holds the document's saves, and removing the block is the only way to clear
/// that hold — so the card has to say so and offer the button.
struct PendingAttachmentImageView: View {
    let alt: String
    let display: PendingAttachmentDisplay
    let onRetry: () -> Void
    let onRemove: () -> Void

    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        switch display {
        case .pending(let data):
            photo(data)
                .overlay(alignment: .bottomLeading) { badge }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(label(loc[.editor_attachment_pending_a11y]))
        case .failed(let data):
            VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
                photo(data).opacity(0.5)
                message(loc[.editor_attachment_failed], icon: .error)
                actions(showsRetry: true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label(loc[.editor_attachment_failed]))
        case .missing:
            VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
                message(loc[.editor_attachment_missing], icon: .image)
                actions(showsRetry: false)
            }
            .padding(DocsSpacing.spaceSM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DocsColor.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: DocsRadius.md))
        }
    }

    /// The photo's own description, when it has one, ahead of the state — `MaterialSymbol` is
    /// accessibility-hidden and the badge text alone would not say what the image is.
    private func label(_ state: String) -> String {
        alt.isEmpty ? state : "\(alt), \(state)"
    }

    @ViewBuilder
    private func photo(_ data: Data) -> some View {
        if let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: DocsRadius.md))
        } else {
            message(loc[.editor_attachment_missing], icon: .image)
        }
    }

    private var badge: some View {
        HStack(spacing: DocsSpacing.space3xs) {
            MaterialSymbol(.cloud_off, size: 14)
            Text(loc[.editor_attachment_pending])
                .font(DocsFont.caption)
        }
        .foregroundStyle(DocsColor.textOnBrand)
        .padding(.horizontal, DocsSpacing.spaceXS)
        .padding(.vertical, DocsSpacing.space3xs)
        // Pinned to the light-scheme ink in *both* schemes: this scrim sits on the user's photo,
        // not on an app surface, so inverting it would put white text on a near-white capsule in
        // dark mode.
        .background(
            Capsule().fill(
                Color(lightHex: DocsColorHex.textPrimary, darkHex: DocsColorHex.textPrimary)
                    .opacity(0.75))
        )
        .padding(DocsSpacing.spaceXS)
    }

    private func message(_ text: String, icon: MaterialIcon) -> some View {
        HStack(spacing: DocsSpacing.spaceXS) {
            MaterialSymbol(icon, size: 16)
            Text(text)
                .font(DocsFont.footnote)
        }
        .foregroundStyle(DocsColor.textSecondary)
    }

    private func actions(showsRetry: Bool) -> some View {
        HStack(spacing: DocsSpacing.spaceSM) {
            if showsRetry {
                actionButton(loc[.editor_attachment_retry], tint: DocsColor.brandFill, action: onRetry)
            }
            actionButton(loc[.editor_attachment_remove], tint: DocsColor.danger, action: onRemove)
        }
    }

    /// A bare `Button` hit-tests the shape its **label** draws, so a floor on the enclosing
    /// `HStack` buys nothing — the stack grows and the labels stay their own text height. The
    /// floor and the `contentShape` go inside, exactly as `SaveStatusIndicator` does it.
    private func actionButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DocsFont.footnote)
                .foregroundStyle(tint)
                .frame(
                    minWidth: DocsSpacing.rowMinHeight, minHeight: DocsSpacing.rowMinHeight,
                    alignment: .leading
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview("Pending attachment states") {
    VStack(alignment: .leading, spacing: DocsSpacing.spaceLG) {
        PendingAttachmentImageView(
            alt: "", display: .pending(previewPNG), onRetry: {}, onRemove: {})
        PendingAttachmentImageView(
            alt: "", display: .failed(previewPNG), onRetry: {}, onRemove: {})
        PendingAttachmentImageView(alt: "", display: .missing, onRetry: {}, onRemove: {})
    }
    .padding()
    .environment(LocalizationStore())
}

#Preview("Pending attachment states — dark") {
    VStack(alignment: .leading, spacing: DocsSpacing.spaceLG) {
        PendingAttachmentImageView(
            alt: "", display: .pending(previewPNG), onRetry: {}, onRemove: {})
        PendingAttachmentImageView(alt: "", display: .missing, onRetry: {}, onRemove: {})
    }
    .padding()
    .environment(LocalizationStore())
    .preferredColorScheme(.dark)
}

/// A tiny solid-colour PNG, built in-process so the previews need no bundled asset.
private var previewPNG: Data {
    let size = CGSize(width: 240, height: 120)
    let renderer = UIGraphicsImageRenderer(size: size)
    let image = renderer.image { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
    return image.pngData() ?? Data()
}
