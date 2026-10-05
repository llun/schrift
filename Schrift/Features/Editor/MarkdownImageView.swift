import SwiftUI

/// Both surfaces render the same image leaf, including when its bytes cannot
/// load. The URL remains a secondary action; a failure never becomes prose.
struct MarkdownImageView: View {
    let alt: String
    let url: URL
    let serverOrigin: String
    var isOffline: Bool = false

    private struct Presentation {
        let url: URL
        let scope: ImageCacheScope?
        let image: UIImage
    }

    @State private var presentation: Presentation?

    @Environment(LocalizationStore.self) private var loc
    @Environment(ImageLoader.self) private var loader

    private struct LoadID: Equatable {
        let url: URL
        let scope: ImageCacheScope?
        let offline: Bool
        let serverOrigin: String
    }

    private var matchesSession: Bool { loader.scope?.serverOrigin == serverOrigin }

    private var readyImage: UIImage? {
        guard matchesSession else { return nil }
        if let presentation, presentation.url == url, presentation.scope == loader.scope {
            return presentation.image
        }
        return loader.image(for: url)
    }

    var body: some View {
        Group {
            if let image = readyImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: DocsRadius.md))
                    .accessibilityLabel(alt.isEmpty ? loc[.editor_image_a11y] : alt)
            } else {
                switch matchesSession ? loader.state(for: url) : .unavailableOffline {
                case .idle, .loading:
                    placeholder
                case .requiresConsent:
                    tapToLoad
                case .unavailableOffline:
                    unavailable(.editor_image_offline, canRetry: false)
                case .failed, .cached:
                    unavailable(.editor_image_failed, canRetry: !isOffline && matchesSession)
                }
            }
        }
        .task(id: LoadID(url: url, scope: loader.scope, offline: isOffline, serverOrigin: serverOrigin)) {
            guard matchesSession else { return }
            await load()
        }
    }

    private func load(retry: Bool = false) async {
        let requestedURL = url
        let requestedScope = loader.scope
        let image: UIImage?
        if retry {
            image = await loader.retry(requestedURL, allowsNetwork: !isOffline)
        } else {
            image = await loader.loadIfNeeded(requestedURL, allowsNetwork: !isOffline)
        }
        guard !Task.isCancelled, requestedURL == url, requestedScope == loader.scope else { return }
        presentation = image.map {
            Presentation(url: requestedURL, scope: requestedScope, image: $0)
        }
    }

    private var tapToLoad: some View {
        Button {
            loader.approve(url)
            Task { await load() }
        } label: {
            HStack(alignment: .top, spacing: DocsSpacing.spaceXS) {
                MaterialSymbol(.image, size: 16)
                    .foregroundStyle(DocsColor.textTertiary)
                VStack(alignment: .leading, spacing: DocsSpacing.space4xs) {
                    Text(loc[.editor_image_external]).foregroundStyle(DocsColor.textBrand)
                    Text(url.host ?? url.absoluteString)
                        .foregroundStyle(DocsColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .font(DocsFont.footnote)
            .padding(DocsSpacing.spaceSM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DocsColor.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: DocsRadius.md))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(loc.format(.editor_image_external_a11y, url.host ?? url.absoluteString))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: DocsRadius.md)
            .fill(DocsColor.surfaceSunken)
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .overlay { ProgressView() }
            .accessibilityLabel(
                alt.isEmpty ? loc[.editor_image_loading_a11y] : loc.format(.editor_image_loading_named_a11y, alt))
    }

    private func unavailable(_ message: L10nKey, canRetry: Bool) -> some View {
        VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
            HStack(spacing: DocsSpacing.spaceXS) {
                MaterialSymbol(.image, size: 24)
                Text(alt.isEmpty ? loc[.editor_image_a11y] : alt)
                    .lineLimit(2)
            }
            .foregroundStyle(DocsColor.textPrimary)
            Text(loc[message]).foregroundStyle(DocsColor.textTertiary)
            Text(url.absoluteString)
                .foregroundStyle(DocsColor.textTertiary)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack {
                if canRetry {
                    Button(loc[.editor_image_retry]) {
                        Task { await load(retry: true) }
                    }
                    .buttonStyle(.plain)
                }
                if isFetchableImageURL(url) {
                    Link(loc[.editor_image_open], destination: url)
                }
            }
            .foregroundStyle(DocsColor.textBrand)
        }
        .font(DocsFont.footnote)
        .padding(DocsSpacing.spaceSM)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
        .background(DocsColor.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: DocsRadius.md))
    }
}
