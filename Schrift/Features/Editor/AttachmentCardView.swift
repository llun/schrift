import QuickLook
import QuickLookThumbnailing
import SwiftUI

/// What an attachment card shows, resolved from the loader's state and whether
/// the app believes it is offline.
///
/// Pure and `Equatable` so the branching is testable without hosting a view —
/// the same reason the design system's style resolvers return raw values.
enum AttachmentCardState: Equatable {
    case downloading
    case cached(URL)
    case failed
    /// Nothing cached and no point asking: show it, say so, issue no request.
    case offlineAndUncached
}

/// Rules, in precedence order:
///   * cached bytes win outright — an attachment downloaded earlier previews in
///     airplane mode, which is the whole point of caching it;
///   * offline and uncached is its own state, not a failure: nothing was tried,
///     so "couldn't download · tap to retry" would be both wrong and useless;
///   * `nil` while online means the card's `.task` is about to start the
///     download, so it reads as `.downloading` rather than flashing a failure.
func attachmentCardState(loaderState: AttachmentLoadState?, isOffline: Bool) -> AttachmentCardState {
    switch loaderState {
    case .cached(let url): return .cached(url)
    case .failed: return isOffline ? .offlineAndUncached : .failed
    case .downloading, nil: return isOffline ? .offlineAndUncached : .downloading
    }
}

/// An uploaded file (PDF, docx, …) rendered inline in a document, with a
/// thumbnail when the system can make one and a full-screen QuickLook preview on
/// tap.
///
/// The bytes come from `AttachmentLoader`, never from this view: it owns the
/// origin-pinned request and the disk cache that makes the attachment readable
/// offline. This view only asks, and renders what it is told.
struct AttachmentCardView: View {
    let display: AttachmentDisplay
    /// Chrome only — it decides whether to *ask*, never whether a cached
    /// attachment opens. Defaulted because a card renders correctly without it;
    /// `serverOrigin`, which gates a request, is not defaulted anywhere.
    var isOffline: Bool = false

    @Environment(AttachmentLoader.self) private var loader
    @Environment(LocalizationStore.self) private var loc
    @Environment(\.displayScale) private var displayScale

    /// Both are keyed to `display.urlString` by the `.task(id:)` below and reset
    /// when it changes: `applyLiveRemoteChange` reuses a surviving block's
    /// `EditorBlock.id`, so this view — and this `@State` — outlives a content
    /// change that swaps the attachment underneath it. A stale thumbnail would
    /// picture the wrong file; a stale `previewURL` would open it.
    @State private var thumbnail: UIImage?
    @State private var previewURL: URL?

    private var state: AttachmentCardState {
        attachmentCardState(loaderState: loader.state(for: display), isOffline: isOffline)
    }

    private var title: String { attachmentDisplayTitle(display) }

    var body: some View {
        content
            // Keyed on the offline flag as well as the url: coming back online
            // must re-fire the load for a card that never got to ask.
            .task(id: "\(display.urlString)|\(isOffline)") {
                guard !isOffline else { return }
                await loader.loadIfNeeded(display)
                await refreshThumbnail()
            }
            .onChange(of: display.urlString) {
                thumbnail = nil
                previewURL = nil
            }
            .quickLookPreview($previewURL)
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .cached(let fileURL):
            Button {
                previewURL = fileURL
            } label: {
                card(subtitle: display.fileExtension.uppercased(), accessory: .chevron)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc.format(.editor_attachment_a11y, title, display.fileExtension.uppercased()))
        case .failed:
            Button {
                Task { await loader.retry(display) }
            } label: {
                card(subtitle: loc[.editor_attachment_failed_retry], accessory: .none, isWarning: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc.format(.editor_attachment_a11y, title, loc[.editor_attachment_failed_retry]))
        case .downloading:
            card(subtitle: loc[.editor_attachment_downloading], accessory: .progress)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(loc.format(.editor_attachment_a11y, title, loc[.editor_attachment_downloading]))
        case .offlineAndUncached:
            card(subtitle: loc[.editor_attachment_offline], accessory: .none)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(loc.format(.editor_attachment_a11y, title, loc[.editor_attachment_offline]))
        }
    }

    private enum Accessory { case chevron, progress, none }

    private func card(subtitle: String, accessory: Accessory, isWarning: Bool = false) -> some View {
        HStack(spacing: DocsSpacing.spaceSM) {
            leading
            VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
                // The title is document content — never localized, and it can be
                // a long file name, so it truncates in the middle where the
                // extension stays readable.
                Text(title)
                    .font(DocsFont.body)
                    .foregroundStyle(DocsColor.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(DocsFont.footnote)
                    .foregroundStyle(isWarning ? DocsColor.textBrand : DocsColor.textTertiary)
            }
            Spacer(minLength: 0)
            switch accessory {
            case .chevron:
                MaterialSymbol(.chevron_right, size: 20)
                    .foregroundStyle(DocsColor.textTertiary)
            case .progress:
                ProgressView()
            case .none:
                EmptyView()
            }
        }
        .padding(DocsSpacing.spaceSM)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A row of text that must never clip as Dynamic Type grows, so a floor
        // rather than a fixed height.
        .frame(minHeight: DocsSpacing.rowMinHeight)
        .background(DocsColor.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: DocsRadius.md))
        .contentShape(RoundedRectangle(cornerRadius: DocsRadius.md))
    }

    /// A real preview of the file when QuickLook can render one, else the
    /// generic document glyph. Both occupy the same box so the row doesn't
    /// resize when a thumbnail arrives.
    private var leading: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                MaterialSymbol(.description, size: 22)
                    .foregroundStyle(DocsColor.textTertiary)
            }
        }
        .frame(width: attachmentThumbnailSide, height: attachmentThumbnailSide)
        .clipShape(RoundedRectangle(cornerRadius: DocsRadius.sm))
    }

    /// Best-effort: a file type with no preview generator (an archive, and on the
    /// Simulator often an Office document) simply keeps the glyph. Never
    /// surfaces an error — a missing thumbnail is not something the user can act
    /// on.
    private func refreshThumbnail() async {
        guard case .cached(let fileURL) = state else { return }
        let key = fileURL.lastPathComponent
        if let cached = AttachmentThumbnailCache.image(for: key) {
            thumbnail = cached
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: attachmentThumbnailSide, height: attachmentThumbnailSide),
            scale: displayScale,
            representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        else { return }
        AttachmentThumbnailCache.store(representation.uiImage, for: key)
        // The url can have changed while the generator worked.
        guard case .cached(let current) = state, current.lastPathComponent == key else { return }
        thumbnail = representation.uiImage
    }
}

private let attachmentThumbnailSide: CGFloat = 40

/// Memory-only, main-actor-isolated thumbnail cache keyed by cache file name.
///
/// Generation is expensive enough that regenerating on every reappear would show
/// as scroll stutter in a document full of attachments, and the images are tiny.
/// Capped anyway, because a long reading session can scroll past many.
@MainActor
private enum AttachmentThumbnailCache {
    private static var images: [String: UIImage] = [:]
    private static var order: [String] = []
    private static let limit = 64

    static func image(for key: String) -> UIImage? { images[key] }

    static func store(_ image: UIImage, for key: String) {
        if images[key] == nil { order.append(key) }
        images[key] = image
        while order.count > limit, !order.isEmpty {
            images.removeValue(forKey: order.removeFirst())
        }
    }
}
