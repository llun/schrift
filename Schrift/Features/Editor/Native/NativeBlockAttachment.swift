import UIKit

/// The layout inputs of attachment paragraphs (PR06e): the text container's
/// usable width and the image aspect ratios known when the surface last
/// restyled. Plain values, so a fresh projection with the same geometry
/// equals storage. A download never changes it: the loaded image fills the
/// box reserved for it, and its ratio applies from the next restyle (a width
/// or Dynamic Type change, or the next open), so nothing below it moves.
struct NativeAttachmentGeometry: Equatable {
    /// Before the first layout pass the view has no width yet.
    static let fallbackWidth: CGFloat = 320
    var width: CGFloat = 0
    /// Width over height, by image URL string.
    var aspectRatios: [String: CGFloat] = [:]

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
        case .image(_, _, let previewWidth):
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
            height =
                2 * padding + detail + lineGap + shown * line(sourceFont(traits))
                + (lineCount > lines.count ? lineGap + detail : 0)
        case .preserved(_, let summary):
            height = 2 * padding + title + (summary.isEmpty ? 0 : lineGap + detail)
        }
        return CGSize(width: width, height: max(minimumHeight, ceil(height)))
    }
}

/// A read-only preview card. Its size never changes after creation: a
/// loaded image is fitted into the reserved box. Built with frames, laid out
/// in `layoutSubviews`, so it costs nothing until TextKit realises it.
@MainActor
final class NativeAttachmentView: UIView {
    let content: NativeAttachmentContent
    private weak var controls: NativeBlockControls?
    private var labels: NativeEditorLabels { controls?.labels ?? NativeEditorLabels() }
    private var traits: UITraitCollection { controls?.traits ?? traitCollection }
    private let stack = UIStackView()
    private(set) var imageView: UIImageView?
    private(set) var imageStatus: UILabel?
    /// "External image · tap to load": a request only after this tap.
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
        }
        build()
        applyTheme()
        if content.preview.isTable || content.preview.isColumns || isMedia {
            // The card opens the table editor (PR11a), the column editor
            // (PR12a) or the media inspector (PR13a).
            accessibilityTraits = [.button]
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openTable)))
        }
    }

    /// A media block's card (PR13a): its node is the attachment's own.
    private var isMedia: Bool {
        switch content.preview {
        case .image: true
        case .file(let node, _, _): MediaBlock.isMediaLike(node)
        default: false
        }
    }

    /// A file card's detail line and its text, which an upload replaces (PR13a).
    private var detail: (label: UILabel, text: String)?

    /// "Uploading…" while this block's upload runs; presentation only.
    func applyUploadState() {
        guard let detail else { return }
        detail.label.text =
            controls?.uploadingBlock == content.blockID && controls?.uploadingBlock != nil
            ? labels.mediaUploading : detail.text
    }

    @objc private func openTable() {
        if content.preview.isColumns {
            controls?.onOpenColumns?(content.blockID)
        } else if isMedia {
            controls?.onOpenMedia?(content.blockID)
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
        if window != nil { loadImageIfNeeded() }
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
        for case let label as UILabel in allSubviews {
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
        case .image:
            buildImage()
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
                label(labels.kind(node), primary: false, font: NativeAttachmentLayout.detailFont(traits)))
            let source = label(
                lines.joined(separator: "\n"), primary: true, font: NativeAttachmentLayout.sourceFont(traits))
            source.numberOfLines = NativeBlockPreview.Limits.maxSourceLines
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

    private func buildImage() {
        guard case .image(_, _, let previewWidth) = content.preview else { return }
        let box = NativeAttachmentLayout.imageWidth(previewWidth: previewWidth, width: content.size.width)
        let image = UIImageView(frame: CGRect(x: 0, y: 0, width: box, height: content.size.height))
        image.contentMode = .scaleAspectFit
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

    // MARK: - Images

    private var imageURL: URL? {
        guard case .image(let url, _, _) = content.preview else { return nil }
        return URL(string: url)
    }

    /// The loader's own rules apply: a same-origin image loads (with the
    /// session's cookies, authenticated media included), an external one
    /// waits for a tap (`ImageLoadPolicy`), cached bytes show without a
    /// request, and offline issues none.
    func loadImageIfNeeded() {
        guard case .image = content.preview, imageView?.image == nil, loadTask == nil else { return }
        guard let url = imageURL, isFetchableImageURL(url) else { return showStatus(labels.imageFailed) }
        guard let controls, controls.images != nil else { return }
        // `MarkdownImageView.matchesSession`: a loader of another server's
        // session shows nothing and requests nothing, as if offline.
        guard let loader = controls.sessionImages else { return showStatus(labels.imageOffline) }
        if let image = loader.image(for: url) { return show(image) }
        let scope = loader.scope
        loadTask = Task { [weak self, loader] in
            let image = await loader.loadIfNeeded(url, allowsNetwork: !controls.isOffline)
            guard let self else { return }
            self.loadTask = nil
            // The session may have changed while the load ran (the classic
            // view's `requestedScope == loader.scope` check).
            guard controls.sessionImages === loader, loader.scope == scope else {
                return self.showStatus(self.labels.imageOffline)
            }
            if let image { return self.show(image) }
            switch loader.state(for: url) {
            case .requiresConsent: self.showConsent(host: url.host ?? url.absoluteString)
            case .unavailableOffline: self.showStatus(self.labels.imageOffline)
            case .failed: self.showStatus(self.labels.imageFailed)
            default: break
            }
        }
    }

    private func show(_ image: UIImage) {
        imageView?.image = image
        imageStatus?.isHidden = true
        loadButton?.removeFromSuperview()
        loadButton = nil
        accessibilityValue = nil
        accessibilityTraits = .image
        backgroundColor = .clear
    }

    private func showStatus(_ text: String) {
        imageStatus?.text = text
        imageStatus?.isHidden = false
        accessibilityValue = text
    }

    private func showConsent(host: String) {
        guard loadButton == nil else { return }
        var configuration = UIButton.Configuration.plain()
        configuration.title = labels.imageExternal
        configuration.subtitle = host
        configuration.image = UIImage(systemName: "photo")
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
        accessibilityValue = String(format: labels.imageExternalA11y, host)
        accessibilityTraits = .button
    }

    /// The tap: consent for this exact URL in this session, then the load.
    func approveAndLoad() {
        guard let url = imageURL, let loader = controls?.sessionImages else { return }
        loader.approve(url)
        loadButton?.removeFromSuperview()
        loadButton = nil
        accessibilityTraits = []
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
        guard loadButton != nil else { return false }
        approveAndLoad()
        return true
    }
}

extension NativeBlockPreview {
    fileprivate var isTable: Bool {
        if case .table = self { return true }
        return false
    }

    fileprivate var isColumns: Bool {
        if case .columns = self { return true }
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
