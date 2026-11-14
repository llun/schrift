import UIKit

/// The layout inputs of attachment paragraphs (PR06e / PR13b2): the text
/// container's usable width, cached document titles, and the image aspect
/// ratios known when the surface last restyled. Plain values, so a fresh
/// projection with the same geometry equals storage. When an image decodes
/// asynchronously, only the affected attachment paragraph(s) are refreshed
/// in place without touching Yjs.
struct NativeAttachmentGeometry: Equatable {
    /// Before the first layout pass the view has no width yet.
    static let fallbackWidth: CGFloat = 320
    var width: CGFloat = 0
    /// Width over height, by image URL string.
    var aspectRatios: [String: CGFloat] = [:]
    /// Cached titles for linked documents shown in inline interlink chips.
    var documentTitles: [UUID: String] = [:]

    var usableWidth: CGFloat { width > 0 ? width : Self.fallbackWidth }
}

/// What one attachment shows. `size` is the view's intrinsic size, which
/// TextKit 2 uses as the attachment's bounds; the attachment sits on the
/// baseline, so its line is `size.height` plus the separator font's descent,
/// and the paragraph's minimum and maximum line height are exactly that
/// (`lineHeight`, the S2 fix): TextKit 2 estimates an unlaid-out attachment
/// paragraph at its final height, before and after the view loads.
struct NativeAttachmentContent: Equatable, Sendable {
    var blockID: String
    var preview: NativeBlockPreview
    /// VoiceOver's name for the block: "Image: alt", "Table, 3 by 4".
    var label: String
    var size: CGSize
    /// The separator font's descent, under the attachment's baseline.
    var descent: CGFloat

    var lineHeight: CGFloat { size.height + descent }
}

/// One preview block's single attachment character. Equal by value, so
/// storage compares equal to a fresh projection (`NSAttributedString.isEqual`
/// compares attribute values) without UIKit object identity.
final class NativeBlockAttachment: NSTextAttachment {
    let content: NativeAttachmentContent

    init(content: NativeAttachmentContent) {
        self.content = content
        super.init(data: nil, ofType: nil)
        // `bounds` stays zero: setting it (as the S2 spike did) makes TextKit 2
        // draw a file icon instead of asking for a view provider (S1 finding 3,
        // confirmed here). The view's intrinsic size is the bounds instead.
        allowsTextAttachmentView = true
    }

    required init?(coder: NSCoder) { nil }

    // Foundation uniques equal attribute values, so two storages may share
    // one equal attachment: it holds only immutable values.
    override func isEqual(_ object: Any?) -> Bool {
        (object as? NativeBlockAttachment)?.content == content
    }

    override var hash: Int { content.blockID.hashValue ^ Int(content.size.height) }

    override var description: String { "NativeBlockAttachment(\(content))" }

    override func viewProvider(
        for parentView: UIView?, location: any NSTextLocation, textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        // TextKit 2 sizes the attachment from the view's intrinsic size, which
        // is `content.size`, the same value the paragraph style was built from
        // before any view existed.
        let provider = NativeAttachmentViewProvider(
            textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager,
            location: location)
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}

/// TextKit 2 asks for a provider only for laid-out attachments, so a preview
/// view exists only around the viewport (bounded realisation).
final class NativeAttachmentViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        // TextKit loads views on the main thread, inside UITextView layout.
        nonisolated(unsafe) let provider = self
        MainActor.assumeIsolated {
            guard let attachment = provider.textAttachment as? NativeBlockAttachment else { return }
            let controls = provider.textLayoutManager?.delegate as? NativeBlockControls
            let view = NativeAttachmentView(content: attachment.content, controls: controls)
            provider.view = view
            controls?.attachmentViewDidLoad(view)
        }
    }
}

/// Sizes, from the preview, the usable width and Dynamic Type. Every height
/// is a whole point and at least the separator's line.
@MainActor
enum NativeAttachmentLayout {
    /// The classic image placeholder's height (`MarkdownImageView`) when no
    /// aspect ratio is known yet.
    static let placeholderImageHeight: CGFloat = 160
    static let maxImageHeight: CGFloat = 640
    static let minImageHeight: CGFloat = DocsSpacing.rowMinHeight
    static let padding = DocsSpacing.spaceSM
    static let cellPadding = DocsSpacing.space2xs
    static let lineGap = DocsSpacing.space4xs

    static func titleFont(_ traits: UITraitCollection) -> UIFont {
        UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
    }

    static func detailFont(_ traits: UITraitCollection) -> UIFont {
        UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits)
    }

    static func sourceFont(_ traits: UITraitCollection) -> UIFont {
        let base = UIFont.monospacedSystemFont(ofSize: DocsTypographySpec.code.size, weight: .regular)
        return UIFontMetrics(forTextStyle: .footnote).scaledFont(for: base, compatibleWith: traits)
    }

    static func line(_ font: UIFont) -> CGFloat { ceil(font.lineHeight) }

    /// The image box's width: BlockNote's `previewWidth`, never wider than the column.
    static func imageWidth(previewWidth: Double?, width: CGFloat) -> CGFloat {
        guard let previewWidth, previewWidth >= 1 else { return width }
        return min(width, ceil(CGFloat(previewWidth)))
    }

    static func size(
        for preview: NativeBlockPreview, width: CGFloat, traits: UITraitCollection, aspectRatio: CGFloat?,
        minimumHeight: CGFloat
    ) -> CGSize {
        let width = max(DocsSpacing.rowMinHeight, floor(width))
        let title = line(titleFont(traits))
        let detail = line(detailFont(traits))
        let height: CGFloat
        switch preview {
        case .image(_, _, let previewWidth), .video(_, _, let previewWidth):
            let box = imageWidth(previewWidth: previewWidth, width: width)
            let natural = aspectRatio.map { box / $0 } ?? placeholderImageHeight
            height = min(maxImageHeight, max(minImageHeight, natural))
        case .file:
            height = 2 * padding + title + lineGap + detail
        case .table(let cells, let rowCount, let columnCount):
            let row = detail + 2 * cellPadding
            let truncated = rowCount > cells.count || columnCount > NativeBlockPreview.Limits.maxColumns
            height = CGFloat(max(1, cells.count) + (truncated ? 1 : 0)) * row
        case .columns(let columns, _):
            let lines = CGFloat(max(1, columns.map(\.count).max() ?? 0))
            height = 2 * padding + lines * detail + (lines - 1) * lineGap
        case .source(_, let lines, let lineCount):
            let shown = CGFloat(max(1, lines.count))
            let bodyLine = line(NativeSourcePreview.sourceCardBodyFont(isEmpty: lines.isEmpty, traits: traits))
            height =
                2 * padding + detail + lineGap + shown * bodyLine
                + (lineCount > lines.count ? lineGap + detail : 0)
        case .preserved(_, let summary):
            height = 2 * padding + title + (summary.isEmpty ? 0 : lineGap + detail)
        }
        return CGSize(width: width, height: max(minimumHeight, ceil(height)))
    }
}

/// A read-only preview card. Built with frames, laid out in `layoutSubviews`,
/// so it costs nothing until TextKit realises it. When an image finishes
/// decoding, it notifies `controls` so the card's height refreshes to the
/// image's aspect ratio.
@MainActor
final class NativeAttachmentView: UIView {
    let content: NativeAttachmentContent
    private weak var controls: NativeBlockControls?
    private var labels: NativeEditorLabels { controls?.labels ?? NativeEditorLabels() }
    private var traits: UITraitCollection { controls?.traits ?? traitCollection }
    private let stack = UIStackView()
    private(set) var imageView: UIImageView?
    private(set) var imageStatus: UILabel?
    private(set) var videoPlayBadge: UIView?
    private(set) var videoCaptionPill: UIView?
    /// "External image/video · tap to load": a request only after this tap.
    private(set) var loadButton: UIButton?
    private(set) var loadTask: Task<Void, Never>?

    init(content: NativeAttachmentContent, controls: NativeBlockControls?) {
        self.content = content
        self.controls = controls
        super.init(frame: CGRect(origin: .zero, size: content.size))
        clipsToBounds = true
        layer.cornerRadius = DocsRadius.md
        isAccessibilityElement = true
        accessibilityLabel = content.label
        accessibilityIdentifier = "nativeEditor.attachment.\(content.blockID)"
        if case .columns(let columns, let count) = content.preview {
            // After the card's name VoiceOver hears each column and its first lines (PR12c).
            accessibilityValue = columns.enumerated().map { index, lines in
                ([String(format: labels.column, index + 1, count)]
                    + lines.map { $0.text.isEmpty ? labels.kind($0.node) : $0.text }).joined(separator: ", ")
            }.joined(separator: "; ")
        } else if case .source(_, let lines, let lineCount) = content.preview {
            accessibilityValue = NativeSourcePreview.blockAccessibilityValue(
                lines: lines, lineCount: lineCount, labels: labels)
        }
        build()
        applyTheme()
        if content.preview.isTable || content.preview.isColumns || isMedia || content.preview.isSource {
            // The card opens the table editor (PR11a), the column editor
            // (PR12a), the media inspector (PR13a), or the source editor (PR14).
            accessibilityTraits = [.button]
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openTable)))
        }
    }

    /// A media block's card (PR13a): its node is the attachment's own.
    private var isMedia: Bool {
        switch content.preview {
        case .image, .video: true
        case .file(let node, _, _): MediaBlock.isMediaLike(node)
        default: false
        }
    }

    private var isVideo: Bool {
        if case .video = content.preview { return true }
        return false
    }

    /// A file card's detail line and its text, which an upload replaces (PR13a).
    private var detail: (label: UILabel, text: String)?

    /// "Uploading…" while this block's upload is queued or runs, "Upload
    /// failed" once it failed; presentation only.
    func applyUploadState() {
        guard let detail else { return }
        let id = content.blockID
        detail.label.text =
            if controls?.failedUploads.contains(id) == true {
                labels.mediaUploadFailed
            } else if controls?.waitingUploads.contains(id) == true {
                labels.mediaUploadWaiting
            } else if controls?.uploadingBlocks.contains(id) == true {
                labels.mediaUploading
            } else {
                detail.text
            }
    }

    @objc private func openTable() {
        if content.preview.isColumns {
            controls?.onOpenColumns?(content.blockID)
        } else if isMedia {
            controls?.onOpenMedia?(content.blockID)
        } else if content.preview.isSource {
            controls?.onOpenSource?(.block(blockID: content.blockID))
        } else {
            controls?.onOpenTable?(content.blockID)
        }
    }

    required init?(coder: NSCoder) { nil }

    // TextKit 2 sizes a tracked attachment view from these; the attachment's
    // bounds and this size are the same value.
    override var intrinsicContentSize: CGSize { content.size }
    override func sizeThatFits(_ size: CGSize) -> CGSize { content.size }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            loadImageIfNeeded()
        } else if isVideo {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    func applyTheme() {
        guard let controls else {
            backgroundColor = .secondarySystemBackground
            return
        }
        // A loaded image shows on a clear card; a theme change keeps it so.
        backgroundColor = imageView?.image == nil ? controls.color(\.surfaceSunken) : .clear
        layer.borderColor = controls.color(\.borderStrong).cgColor
        layer.borderWidth = content.preview.isTable ? 1 / max(1, traitCollection.displayScale) : 0
        for case let label as UILabel in allSubviews where label.tag != 2 {
            label.textColor = label.tag == 1 ? controls.color(\.textPrimary) : controls.color(\.textTertiary)
        }
        loadButton?.tintColor = controls.color(\.textBrand)
    }

    private var allSubviews: [UIView] {
        var result: [UIView] = []
        var queue = subviews
        while let next = queue.popLast() {
            result.append(next)
            queue += next.subviews
        }
        return result
    }

    // MARK: - Building

    private func build() {
        let traits = self.traits
        let padding = NativeAttachmentLayout.padding
        stack.axis = .vertical
        stack.spacing = NativeAttachmentLayout.lineGap
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isAccessibilityElement = false
        func pin(_ inset: CGFloat) {
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                stack.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            ])
        }
        switch content.preview {
        case .image(_, _, let previewWidth):
            buildMediaView(previewWidth: previewWidth, contentMode: .scaleAspectFit)
        case .video(_, let label, let previewWidth):
            buildVideo(label: label, previewWidth: previewWidth)
        case .file(let node, let name, let url):
            pin(padding)
            let kind = labels.kind(node)
            stack.addArrangedSubview(
                label(
                    name.isEmpty ? (URL(string: url)?.lastPathComponent ?? kind) : name, primary: true,
                    font: NativeAttachmentLayout.titleFont(traits)))
            // A media block without a url yet, or a peer's upload (PR13a).
            let detail =
                node == MediaBlock.uploadLoader
                ? labels.uploadElsewhere : url.isEmpty && MediaBlock.nodes.contains(node) ? labels.mediaEmpty : kind
            let detailLabel = label(detail, primary: false, font: NativeAttachmentLayout.detailFont(traits))
            stack.addArrangedSubview(detailLabel)
            self.detail = (detailLabel, detail)
            applyUploadState()
        case .table(let cells, let rowCount, let columnCount):
            pin(0)
            stack.spacing = 0
            let font = NativeAttachmentLayout.detailFont(traits)
            let height = NativeAttachmentLayout.line(font) + 2 * NativeAttachmentLayout.cellPadding
            for (index, row) in cells.enumerated() {
                let line = UIStackView()
                line.axis = .horizontal
                line.distribution = .fillEqually
                line.spacing = 0
                for cell in row
                    + Array(
                        repeating: "", count: max(0, min(columnCount, NativeBlockPreview.Limits.maxColumns) - row.count)
                    )
                {
                    let text = label(cell, primary: true, font: index == 0 ? font.bold : font)
                    let cellView = UIView()
                    cellView.addSubview(text)
                    text.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([
                        text.leadingAnchor.constraint(
                            equalTo: cellView.leadingAnchor, constant: NativeAttachmentLayout.cellPadding),
                        text.trailingAnchor.constraint(
                            equalTo: cellView.trailingAnchor, constant: -NativeAttachmentLayout.cellPadding),
                        text.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                    ])
                    line.addArrangedSubview(cellView)
                }
                line.heightAnchor.constraint(equalToConstant: height).isActive = true
                stack.addArrangedSubview(line)
            }
            if rowCount > cells.count || columnCount > NativeBlockPreview.Limits.maxColumns {
                let more = label(labels.tableMore, primary: false, font: font)
                more.textAlignment = .center
                more.heightAnchor.constraint(equalToConstant: height).isActive = true
                stack.addArrangedSubview(more)
            }
        case .columns(let columns, _):
            pin(padding)
            stack.axis = .horizontal
            stack.distribution = .fillEqually
            stack.spacing = NativeAttachmentLayout.padding
            stack.alignment = .top
            for column in columns {
                let lines = UIStackView()
                lines.axis = .vertical
                lines.spacing = NativeAttachmentLayout.lineGap
                for line in column {
                    let text = line.text.isEmpty ? labels.kind(line.node) : line.text
                    lines.addArrangedSubview(
                        label(text, primary: !line.text.isEmpty, font: NativeAttachmentLayout.detailFont(traits)))
                }
                stack.addArrangedSubview(lines)
            }
        case .source(let node, let lines, let lineCount):
            pin(padding)
            stack.addArrangedSubview(
                label(
                    NativeSourcePreview.headerLabel(for: node, labels: labels), primary: false,
                    font: NativeAttachmentLayout.detailFont(traits)))
            let (bodyText, isEmpty) = NativeSourcePreview.displayBody(lines: lines, labels: labels)
            let bodyFont = NativeSourcePreview.sourceCardBodyFont(isEmpty: isEmpty, traits: traits)
            let source = label(bodyText, primary: !isEmpty, font: bodyFont)
            source.numberOfLines = isEmpty ? 1 : NativeBlockPreview.Limits.maxSourceLines
            source.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(source)
            if lineCount > lines.count {
                stack.addArrangedSubview(
                    label(labels.tableMore, primary: false, font: NativeAttachmentLayout.detailFont(traits)))
            }
        case .preserved(_, let summary):
            pin(padding)
            stack.addArrangedSubview(
                label(content.label, primary: false, font: NativeAttachmentLayout.titleFont(traits)))
            if !summary.isEmpty {
                stack.addArrangedSubview(label(summary, primary: true, font: NativeAttachmentLayout.detailFont(traits)))
            }
        }
    }

    private func label(_ text: String, primary: Bool, font: UIFont) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.tag = primary ? 1 : 0
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.isAccessibilityElement = false
        return label
    }

    private func buildMediaView(previewWidth: Double?, contentMode: UIView.ContentMode) {
        let box = NativeAttachmentLayout.imageWidth(previewWidth: previewWidth, width: content.size.width)
        let image = UIImageView(frame: CGRect(x: 0, y: 0, width: box, height: content.size.height))
        image.contentMode = contentMode
        image.clipsToBounds = true
        image.isAccessibilityElement = false
        addSubview(image)
        imageView = image
        let status = UILabel()
        status.font = NativeAttachmentLayout.detailFont(traits)
        status.textAlignment = .center
        status.numberOfLines = 2
        status.isAccessibilityElement = false
        status.frame = bounds.insetBy(dx: NativeAttachmentLayout.padding, dy: NativeAttachmentLayout.padding)
        status.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(status)
        imageStatus = status
        status.isHidden = true
    }

    private func buildVideo(label: String, previewWidth: Double?) {
        buildMediaView(previewWidth: previewWidth, contentMode: .scaleAspectFill)
        let box = NativeAttachmentLayout.imageWidth(previewWidth: previewWidth, width: content.size.width)
        let cardFrame = CGRect(x: 0, y: 0, width: box, height: content.size.height)

        let badgeSize: CGFloat = 44
        let badge = UIView(
            frame: CGRect(
                x: (cardFrame.width - badgeSize) / 2,
                y: (cardFrame.height - badgeSize) / 2,
                width: badgeSize,
                height: badgeSize))
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        badge.layer.cornerRadius = badgeSize / 2
        badge.clipsToBounds = true
        badge.isUserInteractionEnabled = false
        badge.isAccessibilityElement = false
        badge.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let playIcon = UIImageView(image: UIImage(systemName: "play.fill", withConfiguration: symbolConfig))
        playIcon.tintColor = .white
        playIcon.contentMode = .scaleAspectFit
        playIcon.frame = badge.bounds.insetBy(dx: 12, dy: 12)
        playIcon.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        badge.addSubview(playIcon)
        addSubview(badge)
        videoPlayBadge = badge

        if !label.isEmpty {
            let padding = NativeAttachmentLayout.padding
            let pillInsetX = DocsSpacing.spaceSM
            let pillInsetY: CGFloat = 4
            let captionLabel = UILabel()
            captionLabel.tag = 2
            captionLabel.text = label
            captionLabel.font = NativeAttachmentLayout.detailFont(traits)
            captionLabel.textColor = .white
            captionLabel.numberOfLines = 1
            captionLabel.lineBreakMode = .byTruncatingTail
            captionLabel.isAccessibilityElement = false

            let maxTextWidth = max(0, cardFrame.width - padding * 2 - pillInsetX * 2)
            let textSize = captionLabel.sizeThatFits(CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude))
            let pillWidth = min(max(0, cardFrame.width - padding * 2), ceil(textSize.width) + pillInsetX * 2)
            let pillHeight = ceil(textSize.height) + pillInsetY * 2

            let pill = UIView(
                frame: CGRect(
                    x: padding,
                    y: max(padding, cardFrame.height - padding - pillHeight),
                    width: pillWidth,
                    height: pillHeight))
            pill.backgroundColor = UIColor.black.withAlphaComponent(0.6)
            pill.layer.cornerRadius = DocsRadius.sm
            pill.clipsToBounds = true
            pill.isUserInteractionEnabled = false
            pill.isAccessibilityElement = false
            pill.autoresizingMask = [.flexibleTopMargin, .flexibleRightMargin]

            captionLabel.frame = pill.bounds.insetBy(dx: pillInsetX, dy: pillInsetY)
            captionLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            pill.addSubview(captionLabel)
            addSubview(pill)
            videoCaptionPill = pill
        }
    }

    // MARK: - Images & Video Posters

    private var mediaURLString: String? {
        switch content.preview {
        case .image(let url, _, _), .video(let url, _, _): url
        default: nil
        }
    }

    private var imageURL: URL? {
        mediaURLString.flatMap { URL(string: $0) }
    }

    private func aspectRatioKey(for url: URL) -> String {
        isVideo ? VideoPosterLoader.posterKey(for: url) : url.absoluteString
    }

    /// Loads inline media previews through the policy- and cache-backed loaders
    /// (`ImageLoader` for images, `VideoPosterLoader` for video poster frames).
    func loadImageIfNeeded() {
        guard content.preview.isInlineMedia, imageView?.image == nil, loadTask == nil else { return }
        guard let url = imageURL, isFetchableImageURL(url) else {
            if !isVideo { showStatus(labels.imageFailed) }
            return
        }
        guard let controls else { return }

        if isVideo {
            loadVideoPosterIfNeeded(url: url, controls: controls)
        } else {
            loadPhotoIfNeeded(url: url, controls: controls)
        }
    }

    private func loadPhotoIfNeeded(url: URL, controls: NativeBlockControls) {
        guard controls.images != nil else { return }
        // `MarkdownImageView.matchesSession`: a loader of another server's
        // session shows nothing and requests nothing, as if offline.
        guard let loader = controls.sessionImages else { return showStatus(labels.imageOffline) }
        let ratioKey = aspectRatioKey(for: url)
        if controls.isExternalMediaApproved(ratioKey) {
            loader.approve(url)
        }
        if let image = loader.image(for: url) {
            presentLoadedMedia(
                image, ratioKey: ratioKey,
                currentAspectRatio: loader.aspectRatio(for: url), controls: controls)
            return
        }
        let scope = loader.scope
        loadTask = Task { [weak self, loader] in
            let image = await loader.loadIfNeeded(url, allowsNetwork: !controls.isOffline)
            guard let self, !Task.isCancelled else { return }
            self.loadTask = nil
            // The session may have changed while the load ran (the classic
            // view's `requestedScope == loader.scope` check).
            guard controls.sessionImages === loader, loader.scope == scope else {
                return self.showStatus(self.labels.imageOffline)
            }
            if let image {
                self.presentLoadedMedia(
                    image, ratioKey: ratioKey,
                    currentAspectRatio: loader.aspectRatio(for: url), controls: controls)
                return
            }
            self.handleLoadFailureState(
                loader.state(for: url), url: url, offlineText: self.labels.imageOffline,
                failedText: self.labels.imageFailed)
        }
    }

    private func loadVideoPosterIfNeeded(url: URL, controls: NativeBlockControls) {
        guard controls.posters != nil else { return }
        guard let loader = controls.sessionPosters else { return showStatus(labels.videoOffline) }
        let ratioKey = aspectRatioKey(for: url)
        if controls.isExternalMediaApproved(ratioKey) {
            loader.approve(url)
        }
        if let image = loader.poster(for: url) {
            presentLoadedMedia(
                image, ratioKey: ratioKey,
                currentAspectRatio: loader.posterAspectRatio(for: url), controls: controls)
            return
        }
        let scope = loader.scope
        loadTask = Task { [weak self, loader] in
            let image = await loader.loadIfNeeded(url, allowsNetwork: !controls.isOffline)
            guard let self, !Task.isCancelled else { return }
            self.loadTask = nil
            guard controls.sessionPosters === loader, loader.scope == scope else {
                return self.showStatus(self.labels.videoOffline)
            }
            if let image {
                self.presentLoadedMedia(
                    image, ratioKey: ratioKey,
                    currentAspectRatio: loader.posterAspectRatio(for: url), controls: controls)
                return
            }
            // On `.failed` (e.g. >20 MB or unextractable), keep the clean video
            // card with its play badge + optional caption pill instead of an error overlay.
            self.handleLoadFailureState(
                loader.state(for: url), url: url, offlineText: self.labels.videoOffline, failedText: nil)
        }
    }

    private func presentLoadedMedia(
        _ image: UIImage,
        ratioKey: String,
        currentAspectRatio: CGFloat?,
        controls: NativeBlockControls
    ) {
        show(image)
        if controls.surface?.attachmentGeometry.aspectRatios[ratioKey] != currentAspectRatio {
            controls.noteMediaAspectRatioLoaded(for: ratioKey)
        }
    }

    private func handleLoadFailureState(
        _ state: ImageLoadState,
        url: URL,
        offlineText: String,
        failedText: String?
    ) {
        switch state {
        case .requiresConsent: showConsent(host: url.host ?? url.absoluteString)
        case .unavailableOffline: showStatus(offlineText)
        case .failed:
            if let failedText { showStatus(failedText) }
            updateVideoOverlayVisibility()
        default: break
        }
    }

    private func show(_ image: UIImage) {
        imageView?.image = image
        imageStatus?.isHidden = true
        loadButton?.removeFromSuperview()
        loadButton = nil
        accessibilityValue = nil
        accessibilityTraits = isVideo ? [.button] : .image
        backgroundColor = .clear
        updateVideoOverlayVisibility()
    }

    private func showStatus(_ text: String) {
        imageStatus?.text = text
        imageStatus?.isHidden = false
        accessibilityValue = text
        updateVideoOverlayVisibility()
    }

    private func showConsent(host: String) {
        guard loadButton == nil else { return }
        var configuration = UIButton.Configuration.plain()
        configuration.title = isVideo ? labels.videoExternal : labels.imageExternal
        configuration.subtitle = host
        configuration.image = UIImage(systemName: isVideo ? "play.rectangle" : "photo")
        configuration.imagePadding = DocsSpacing.spaceXS
        configuration.titleLineBreakMode = .byTruncatingMiddle
        configuration.subtitleLineBreakMode = .byTruncatingMiddle
        let button = UIButton(configuration: configuration)
        button.isAccessibilityElement = false
        button.frame = bounds
        button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        button.addAction(UIAction { [weak self] _ in self?.approveAndLoad() }, for: .primaryActionTriggered)
        addSubview(button)
        loadButton = button
        applyTheme()
        accessibilityValue = String(format: isVideo ? labels.videoExternalA11y : labels.imageExternalA11y, host)
        accessibilityTraits = .button
        updateVideoOverlayVisibility()
    }

    private func updateVideoOverlayVisibility() {
        let overlayHidden = loadButton != nil || imageStatus?.isHidden == false
        videoPlayBadge?.isHidden = overlayHidden
        videoCaptionPill?.isHidden = overlayHidden
    }

    /// The tap: consent for this exact URL in this session, then the load.
    func approveAndLoad() {
        guard let url = imageURL else { return }
        let approvedLoader: AnyObject?
        if isVideo {
            controls?.sessionPosters?.approve(url)
            approvedLoader = controls?.sessionPosters
        } else {
            controls?.sessionImages?.approve(url)
            approvedLoader = controls?.sessionImages
        }
        guard approvedLoader != nil else { return }
        controls?.approveExternalMedia(aspectRatioKey(for: url))
        loadButton?.removeFromSuperview()
        loadButton = nil
        accessibilityTraits = isVideo ? [.button] : []
        updateVideoOverlayVisibility()
        loadImageIfNeeded()
    }

    override func accessibilityActivate() -> Bool {
        if content.preview.isTable, controls?.onOpenTable != nil {
            openTable()
            return true
        }
        if content.preview.isColumns, controls?.onOpenColumns != nil {
            openTable()
            return true
        }
        if isMedia, loadButton == nil, controls?.onOpenMedia != nil {
            openTable()
            return true
        }
        if content.preview.isSource, controls?.onOpenSource != nil {
            openTable()
            return true
        }
        guard loadButton != nil else { return false }
        approveAndLoad()
        return true
    }
}

extension NativeBlockPreview {
    fileprivate var isInlineMedia: Bool {
        switch self {
        case .image, .video: true
        default: false
        }
    }

    fileprivate var isTable: Bool {
        if case .table = self { return true }
        return false
    }

    fileprivate var isColumns: Bool {
        if case .columns = self { return true }
        return false
    }

    fileprivate var isSource: Bool {
        if case .source = self { return true }
        return false
    }
}

extension UIFont {
    fileprivate var bold: UIFont {
        fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: pointSize) } ?? self
    }
}

extension NativeEditorLabels {
    /// A block family's name: "Video", "Math", or the node name itself.
    func kind(_ node: String) -> String {
        switch node {
        case "image": image
        case "video": video
        case "audio": audio
        case "file": file
        case "pdf": pdf
        case MediaBlock.uploadLoader: uploadElsewhere
        case "mathBlock": math
        case "diagram": diagram
        case "": unknownBlock
        default: node
        }
    }
}
