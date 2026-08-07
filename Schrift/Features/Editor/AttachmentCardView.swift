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

    /// One value scales the leading box and its glyph together (see `leading`).
    @ScaledMetric(relativeTo: .body) private var thumbnailScale: CGFloat = 1

    private var state: AttachmentCardState {
        attachmentCardState(loaderState: loader.state(for: display), isOffline: isOffline)
    }

    private var title: String { attachmentDisplayTitle(display) }

    var body: some View {
        content
            // Keyed on the offline flag as well as the url: coming back online
            // must re-fire the load for a card that never got to ask.
            .task(id: "\(display.urlString)|\(isOffline)") {
                // Note this runs offline too — it is the disk read that makes a
                // previously downloaded attachment openable in airplane mode.
                // Only the *network* is withheld (`allowsNetwork`).
                await loader.loadIfNeeded(display, allowsNetwork: !isOffline)
                await refreshThumbnail()
            }
            // The task's id doesn't change when the loader resolves, so a card
            // that arrived at `.cached` some other way — a second card for the
            // same attachment whose download was de-duplicated, or a successful
            // retry — would otherwise keep the placeholder glyph forever.
            .onChange(of: state) { _, newState in
                guard case .cached = newState else { return }
                Task { await refreshThumbnail() }
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
            if attachmentIsPreviewable(display) {
                Button {
                    // Revalidated through the loader rather than opening
                    // `fileURL` directly: eviction can delete the file while
                    // this card sits on screen (the reading surface is not
                    // lazy, so an off-screen card never re-runs its `.task`),
                    // and QuickLook on a deleted path is a blank sheet with no
                    // way back. This re-downloads if needed and bumps recency.
                    Task {
                        await loader.loadIfNeeded(display, allowsNetwork: !isOffline)
                        if case .cached(let current) = loader.state(for: display) { previewURL = current }
                    }
                } label: {
                    card(subtitle: display.fileExtension.uppercased(), accessory: .chevron)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc.format(.editor_attachment_a11y, title, display.fileExtension.uppercased()))
            } else {
                // Downloaded and cached, but never handed to QuickLook — see
                // `attachmentIsPreviewable`. Rendered inert rather than hidden:
                // the document does link this file, and saying so is honest.
                card(subtitle: loc[.editor_attachment_not_previewable], accessory: .none)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        loc.format(.editor_attachment_a11y, title, loc[.editor_attachment_not_previewable]))
            }
        case .failed:
            Button {
                Task {
                    await loader.retry(display)
                    await refreshThumbnail()
                }
            } label: {
                card(subtitle: loc[.editor_attachment_failed_retry], accessory: .none, isFailure: true)
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

    private func card(subtitle: String, accessory: Accessory, isFailure: Bool = false) -> some View {
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
                    // `danger`, matching SaveStatusIndicator's `.retry` — the
                    // app's established register for "this didn't work, tap to
                    // try again". The brand colour reads as an ordinary link.
                    .foregroundStyle(isFailure ? DocsColor.danger : DocsColor.textTertiary)
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
    ///
    /// Glyph and box scale **together** from one value, the `DocIcon` pattern:
    /// `MaterialSymbol` scales with Dynamic Type by default, so a fixed box
    /// would crop the glyph at accessibility sizes, and freezing the glyph
    /// instead (`scales: false`) would leave it stranded beside text three times
    /// its height.
    private var leading: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                MaterialSymbol(.description, size: attachmentThumbnailGlyphSide, scales: false)
                    .foregroundStyle(DocsColor.textTertiary)
            }
        }
        .frame(width: scaledThumbnailSide, height: scaledThumbnailSide)
        .clipShape(RoundedRectangle(cornerRadius: DocsRadius.sm))
    }

    private var scaledThumbnailSide: CGFloat { attachmentThumbnailSide * thumbnailScale }
    private var attachmentThumbnailGlyphSide: CGFloat { 22 * thumbnailScale }

    /// Best-effort: a file type with no preview generator (an archive, and on the
    /// Simulator often an Office document) simply keeps the glyph. Never
    /// surfaces an error — a missing thumbnail is not something the user can act
    /// on.
    private func refreshThumbnail() async {
        guard case .cached(let fileURL) = state else { return }
        // Keyed by the rendered size as well as the file: a thumbnail generated
        // at the default text size would be resampled soft at an accessibility
        // one, and the two must not share a cache entry.
        let side = scaledThumbnailSide
        // The cache file name carries both server ids, so this key cannot
        // conflate two documents' attachments the way the bare file id would.
        let key = "\(fileURL.lastPathComponent)@\(Int(side.rounded()))"
        if let cached = AttachmentThumbnailCache.image(for: key) {
            thumbnail = cached
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: side, height: side),
            scale: displayScale,
            representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        else { return }
        AttachmentThumbnailCache.store(representation.uiImage, for: key)
        // The url can have changed while the generator worked. Checking
        // cancellation is the only test that actually holds: `state` reads
        // through `display`, which is the view value *this task captured*, so a
        // stale task compares the old attachment against itself and always
        // agrees with itself. `.task(id:)` cancels the superseded task, and
        // QuickLook's completion-handler bridge resumes it regardless — so
        // without this it would write the previous file's image into a `@State`
        // box that survives the swap, and the card would show B's title beside
        // A's thumbnail.
        guard !Task.isCancelled else { return }
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

// MARK: - Preview catalog

/// Every state the card can render, each produced without a network request:
/// `.cached` and the not-previewable variant from a seeded temp cache, `.failed`
/// from a loader whose empty server origin makes `attachmentMediaPath` refuse
/// (so `download` fails immediately and asks for nothing), and
/// `.offlineAndUncached` from an empty loader plus `isOffline`. `.downloading` is
/// the transient between them and is pinned by `attachmentCardState`'s tests.
private struct AttachmentCardCatalog: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DocsSpacing.spaceSM) {
            if let pdf = Self.display(ext: "pdf", label: "Q3 report.pdf") {
                AttachmentCardView(display: pdf)
                    .environment(Self.seededLoader)
            }
            if let unnamed = Self.display(ext: "pdf", label: "", file: "33333333-3333-4333-8333-333333333333") {
                AttachmentCardView(display: unnamed)
                    .environment(AttachmentLoader.inert())
            }
            if let offline = Self.display(ext: "docx", label: "Meeting notes.docx") {
                AttachmentCardView(display: offline, isOffline: true)
                    .environment(AttachmentLoader.inert())
            }
            if let markup = Self.display(ext: "html", label: "export.html", file: Self.markupFileUUID) {
                AttachmentCardView(display: markup)
                    .environment(Self.seededLoader)
            }
        }
        .padding()
    }

    private static let origin = "https://docs.llun.dev"
    private static let documentUUID = "11111111-1111-4111-8111-111111111111"
    private static let markupFileUUID = "44444444-4444-4444-8444-444444444444"

    private static func display(ext: String, label: String, file: String = "22222222-2222-4222-8222-222222222222")
        -> AttachmentDisplay?
    {
        parseAttachmentLink(
            "[\(label)](\(origin)/media/\(documentUUID)/attachments/\(file).\(ext))", serverOrigin: origin)
    }

    @MainActor private static let seededLoader: AttachmentLoader = {
        let cache = AttachmentCacheStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("SchriftPreviewAttachmentCards", isDirectory: true))
        if let pdf = display(ext: "pdf", label: "Q3 report.pdf") {
            _ = cache.store(Data("%PDF-1.4\n%preview\n".utf8), for: pdf)
        }
        if let markup = display(ext: "html", label: "export.html", file: markupFileUUID) {
            _ = cache.store(Data("<html></html>".utf8), for: markup)
        }
        return AttachmentLoader(
            client: DocsAPIClient(baseURL: URL(string: "\(origin)/api/v1.0/")!),
            serverOrigin: origin,
            cache: cache)
    }()
}

#Preview("Light") {
    AttachmentCardCatalog()
        .environment(LocalizationStore())
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    AttachmentCardCatalog()
        .environment(LocalizationStore())
        .preferredColorScheme(.dark)
}
