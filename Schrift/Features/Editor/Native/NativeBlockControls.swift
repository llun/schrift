import SwiftUI
import UIKit

/// The native surface's real, accessible block controls: a checkbox button per
/// visible checklist item, a language menu per visible code block and a
/// disclosure button per visible toggle, placed over their fragments, plus the
/// VoiceOver Headings rotor. Each checkbox or language action is one durable
/// prop command through the input coordinator; without one (the read-only
/// reader) those controls show their state but are disabled. Folding is view
/// state, so the disclosure button works in the reader too.
///
/// Also the TextKit 2 layout delegate, so every fragment is a
/// `NativeBlockFragment` that reads its theme and labels here, and the content
/// storage delegate that leaves a folded toggle's children out of layout.
@MainActor
final class NativeBlockControls: NSObject, @preconcurrency NSTextLayoutManagerDelegate,
    @preconcurrency NSTextContentStorageDelegate, UIGestureRecognizerDelegate
{
    private weak var textView: NativeTextView?
    /// The surface whose fold state decides which paragraphs are laid out.
    weak var surface: NativeTextSurface? {
        didSet {
            connectAspectRatios()
            connectDocumentTitle()
        }
    }
    private(set) var checkboxes: [String: UIButton] = [:]
    private(set) var languageButtons: [String: UIButton] = [:]
    private(set) var toggleButtons: [String: UIButton] = [:]

    /// The display theme (a personal preference, never document data). A
    /// change only redraws.
    var theme: AppTheme = .white {
        didSet { if theme != oldValue { invalidateChrome() } }
    }
    var labels = NativeEditorLabels() {
        didSet { if labels != oldValue { invalidateChrome() } }
    }
    var traits: UITraitCollection { textView?.traitCollection ?? .current }

    // MARK: Attachment previews (PR06e)

    /// The app's image loader (`ImageLoader`, the classic surfaces' owner of
    /// requests, consent and the offline cache). Nil issues no request: image
    /// previews stay placeholders.
    var images: ImageLoader? {
        didSet { if images !== oldValue { connectAspectRatios() } }
    }

    /// The document's server origin (`siteOrigin(for: serverURL)`). Images
    /// load only through a loader whose session is this server's, as the
    /// classic `MarkdownImageView.matchesSession` requires.
    var serverOrigin = "" {
        didSet { if serverOrigin != oldValue { connectAspectRatios() } }
    }

    /// `images`, only while its session belongs to this document's server.
    var sessionImages: ImageLoader? {
        guard let images, images.scope?.serverOrigin == serverOrigin else { return nil }
        return images
    }

    private func connectAspectRatios() {
        guard images != nil else {
            surface?.aspectRatio = nil
            return
        }
        surface?.aspectRatio = { [weak self] url in
            guard let loader = self?.sessionImages else { return nil }
            return URL(string: url).flatMap { loader.aspectRatio(for: $0) }
        }
    }

    /// Cached title resolver for linked document chips, wired from the editor view model.
    var documentTitle: (@MainActor (UUID) -> String?)? {
        didSet { connectDocumentTitle() }
    }

    private func connectDocumentTitle() {
        surface?.documentTitle = documentTitle
        if documentTitle != nil {
            surface?.refreshAttachmentGeometry()
        }
    }
    /// Offline, the loader shows cached bytes and issues no request.
    var isOffline = false
    /// A tap (or VoiceOver activation) on a table's card opens the table
    /// editor (PR11a), with the block id.
    var onOpenTable: ((String) -> Void)?
    /// A tap (or VoiceOver activation) on a column group's card opens the
    /// column editor (PR12a), with the group's block id.
    var onOpenColumns: ((String) -> Void)?
    /// A tap (or VoiceOver activation) on a media block's card opens its
    /// inspector (PR13a), with the block id.
    var onOpenMedia: ((String) -> Void)?
    /// A tap (or VoiceOver action) on an enabled inline page link chip opens
    /// that document (PR13c1), with the target UUID and optional `blockId`.
    var onOpenDocument: ((UUID, String) -> Void)?
    /// The media blocks whose upload is queued or runs (PR13a, PR13b), and
    /// those whose upload failed: their realised cards say so.
    var uploadingBlocks: Set<String> = [] {
        didSet {
            guard uploadingBlocks != oldValue else { return }
            for view in attachmentViews.allObjects { view.applyUploadState() }
        }
    }
    var waitingUploads: Set<String> = [] {
        didSet {
            guard waitingUploads != oldValue else { return }
            for view in attachmentViews.allObjects { view.applyUploadState() }
        }
    }
    var failedUploads: Set<String> = [] {
        didSet {
            guard failedUploads != oldValue else { return }
            for view in attachmentViews.allObjects { view.applyUploadState() }
        }
    }
    /// Every preview view TextKit realised: the bounded-realisation seam.
    private(set) var attachmentViewLoads = 0
    let attachmentViews = NSHashTable<NativeAttachmentView>.weakObjects()

    func attachmentViewDidLoad(_ view: NativeAttachmentView) {
        attachmentViewLoads += 1
        attachmentViews.add(view)
    }

    /// The realised previews currently in the view hierarchy.
    var visibleAttachmentViews: [NativeAttachmentView] {
        attachmentViews.allObjects.filter { $0.window != nil && $0.superview != nil }
    }

    /// Tells the surface the usable width, before UIKit lays out text, so
    /// attachment paragraphs are sized for this width. A storage edit only
    /// when the width (or a known image ratio) changed.
    func updateAttachmentWidth() {
        guard let textView, let surface else { return }
        let width =
            textView.bounds.width - textView.textContainerInset.left - textView.textContainerInset.right - 2
            * textView.textContainer.lineFragmentPadding
        guard width > 0, width.rounded(.down) != surface.attachmentGeometry.width else { return }
        surface.updateAttachmentWidth(width)
    }

    /// Offered in the code block's menu; a block's own language is always
    /// listed too, so no stored value is hidden or rewritten.
    static let codeLanguages = [
        "text", "bash", "c", "cpp", "csharp", "css", "go", "html", "java", "javascript", "json", "kotlin",
        "markdown", "php", "python", "ruby", "rust", "sql", "swift", "typescript", "xml", "yaml",
    ]

    init(textView: NativeTextView) {
        self.textView = textView
        super.init()
        // A patch (a tick, a language, a peer's edit) changes the attributes the
        // controls show; re-place them on the next layout pass.
        NotificationCenter.default.addObserver(
            self, selector: #selector(storageDidEdit), name: NSTextStorage.didProcessEditingNotification,
            object: textView.textStorage)
    }

    @objc private func storageDidEdit() {
        textView?.setNeedsLayout()
    }

    func color(_ role: KeyPath<DocsColors, Color>) -> UIColor {
        UIColor(theme.colors[keyPath: role]).resolvedColor(with: traits)
    }

    // MARK: - NSTextLayoutManagerDelegate

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let fragment = NativeBlockFragment(textElement: textElement, range: textElement.elementRange)
        fragment.controls = self
        return fragment
    }

    // MARK: - NSTextContentStorageDelegate (folding)

    /// A folded toggle's children are not enumerated, so TextKit 2 neither
    /// lays them out nor draws them, and the viewport, caret navigation and
    /// controls skip them. Storage still holds them: the surface equals the
    /// projection while they are hidden.
    func textContentManager(
        _ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement,
        options: NSTextContentManager.EnumerationOptions = []
    ) -> Bool {
        guard let surface, let location = textElement.elementRange?.location else { return true }
        let offset = textContentManager.offset(from: textContentManager.documentRange.location, to: location)
        return !surface.isHidden(atUTF16: offset)
    }

    /// Re-lays out after a fold change. Storage and the replica are untouched.
    func foldDidChange() {
        invalidateChrome()
    }

    /// Redraws the laid-out fragments (theme, labels, light/dark). Storage and
    /// the replica are untouched; TextKit re-lays out only the viewport.
    func invalidateChrome() {
        for view in attachmentViews.allObjects { view.applyTheme() }
        guard let textView, let layout = textView.textLayoutManager else { return }
        layout.invalidateLayout(for: layout.documentRange)
        textView.setNeedsLayout()
    }

    // MARK: - Controls over the viewport

    /// Places a control over each visible checklist item and code block and
    /// drops the rest: work is bounded by the viewport, never the document.
    func layoutControls() {
        guard let textView, let layout = textView.textLayoutManager else { return }
        // UIKit lays out the viewport after this view's own layout pass; settle
        // it first so the controls match what is on screen now.
        layout.textViewportLayoutController.layoutViewport()
        guard let viewport = layout.textViewportLayoutController.viewportRange else { return }
        let enabled = textView.isEditable && textView.inputCoordinator != nil
        var visibleChecks = Set<String>()
        var visibleCode = Set<String>()
        var visibleToggles = Set<String>()
        layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else {
                return false
            }
            guard let fragment = fragment as? NativeBlockFragment, let id = fragment.blockID,
                let paragraph = fragment.textElement as? NSTextParagraph, paragraph.attributedString.length > 0
            else { return true }
            let attributes = paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: textView.textContainerInset.top)
            // Where this block's text starts, from the view's leading edge.
            let indent = (attributes[.paragraphStyle] as? NSParagraphStyle)?.headIndent ?? 0
            let lead = textView.textContainerInset.left + textView.textContainer.lineFragmentPadding
            if attributes[.nativeToggle] as? Bool == true {
                visibleToggles.insert(id)
                let midY = fragment.firstLineMetrics?.midY ?? frame.height / 2
                let size = DocsSpacing.rowMinHeight
                let button = toggleButtons[id] ?? makeToggle(id)
                configure(toggle: button, expanded: surface?.isExpanded(id) == true)
                let inset = CGFloat(attributes[.nativeDepth] as? Int ?? 0) * gutter(textView)
                button.frame = CGRect(
                    x: lead + inset + (indent - inset) / 2 - size / 2, y: frame.minY + midY - size / 2, width: size,
                    height: size)
            }
            switch fragment.blockType {
            case "checkListItem":
                visibleChecks.insert(id)
                let midY = fragment.firstLineMetrics?.midY ?? frame.height / 2
                let size = DocsSpacing.rowMinHeight
                let button = checkboxes[id] ?? makeCheckbox(id)
                configure(checkbox: button, checked: attributes[.nativeChecked] as? Bool == true, enabled: enabled)
                // The gutter after the depth's indent (PR06a).
                let inset = CGFloat(attributes[.nativeDepth] as? Int ?? 0) * gutter(textView)
                button.frame = CGRect(
                    x: lead + inset + (indent - inset) / 2 - size / 2, y: frame.minY + midY - size / 2, width: size,
                    height: size)
            case "codeBlock":
                visibleCode.insert(id)
                let language = attributes[.nativeCodeLanguage] as? String ?? "text"
                let button = languageButtons[id] ?? makeLanguageButton(id)
                configure(language: button, blockID: id, language: language, enabled: enabled)
                let header = (attributes[.paragraphStyle] as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0
                let top = frame.minY + (fragment.firstLineMetrics?.minY ?? header) - header
                let width = (layout.textContainer?.size.width ?? frame.width) - indent
                let fitted = button.sizeThatFits(CGSize(width: width, height: header))
                button.frame = CGRect(
                    x: lead + indent, y: top, width: min(fitted.width, width), height: max(header, DocsSpacing.spaceLG))
            default:
                break
            }
            return true
        }
        for (id, button) in checkboxes where !visibleChecks.contains(id) {
            button.removeFromSuperview()
            checkboxes[id] = nil
        }
        for (id, button) in languageButtons where !visibleCode.contains(id) {
            button.removeFromSuperview()
            languageButtons[id] = nil
        }
        for (id, button) in toggleButtons where !visibleToggles.contains(id) {
            button.removeFromSuperview()
            toggleButtons[id] = nil
        }
    }

    private func gutter(_ textView: UITextView) -> CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(
            for: NativeBlockMetrics.listGutter, compatibleWith: textView.traitCollection)
    }

    /// The disclosure triangle: a real button whose value says whether the
    /// toggle is expanded. A tap folds or unfolds it (view state only).
    private func makeToggle(_ blockID: String) -> UIButton {
        let button = UIButton(configuration: .plain())
        button.isAccessibilityElement = true
        button.accessibilityIdentifier = "nativeEditor.toggle.\(blockID)"
        button.addAction(
            UIAction { [weak self] _ in
                guard let surface = self?.surface else { return }
                surface.setExpanded(blockID, !surface.isExpanded(blockID))
            }, for: .primaryActionTriggered)
        textView?.addSubview(button)
        toggleButtons[blockID] = button
        return button
    }

    private func configure(toggle button: UIButton, expanded: Bool) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: expanded ? "chevron.down" : "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium))
        configuration.baseForegroundColor = color(\.textSecondary)
        button.configuration = configuration
        // BlockNote's fixed name, with the state as the value (`aria-expanded`).
        button.accessibilityLabel = labels.toggle
        button.accessibilityValue = expanded ? labels.expanded : labels.collapsed
        button.accessibilityExpandedStatus = expanded ? .expanded : .collapsed
        button.accessibilityTraits = .button
    }

    private func makeCheckbox(_ blockID: String) -> UIButton {
        let button = UIButton(configuration: .plain())
        button.isAccessibilityElement = true
        button.accessibilityIdentifier = "nativeEditor.checkbox.\(blockID)"
        button.addAction(
            UIAction { [weak self] _ in _ = self?.textView?.inputCoordinator?.toggleCheckbox(blockID: blockID) },
            for: .primaryActionTriggered)
        textView?.addSubview(button)
        checkboxes[blockID] = button
        return button
    }

    private func configure(checkbox button: UIButton, checked: Bool, enabled: Bool) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: checked ? "checkmark.square.fill" : "square",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .title3))
        configuration.baseForegroundColor = checked ? color(\.brandFill) : color(\.textTertiary)
        button.configuration = configuration
        button.isEnabled = enabled
        // The classic checkbox's words: the action as the label, the state as the value.
        button.accessibilityLabel = checked ? labels.markNotDone : labels.markDone
        button.accessibilityValue = checked ? labels.done : labels.notDone
        button.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
    }

    private func makeLanguageButton(_ blockID: String) -> UIButton {
        let button = UIButton(configuration: .plain())
        button.isAccessibilityElement = true
        button.accessibilityIdentifier = "nativeEditor.codeLanguage.\(blockID)"
        button.showsMenuAsPrimaryAction = true
        textView?.addSubview(button)
        languageButtons[blockID] = button
        return button
    }

    private func configure(language button: UIButton, blockID: String, language: String, enabled: Bool) {
        button.isEnabled = enabled
        button.accessibilityLabel = labels.codeLanguage
        button.accessibilityValue = language
        // Rebuilt only when the language changes, not on every scroll.
        guard button.configuration?.title != language || button.menu == nil else { return }
        var configuration = UIButton.Configuration.plain()
        configuration.title = language
        configuration.image = UIImage(
            systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption2))
        configuration.imagePlacement = .trailing
        configuration.imagePadding = DocsSpacing.space3xs
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = color(\.textSecondary)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .footnote)
            return attributes
        }
        button.configuration = configuration
        let options = Self.codeLanguages.contains(language) ? Self.codeLanguages : [language] + Self.codeLanguages
        button.menu = UIMenu(
            title: labels.codeLanguage,
            children: options.map { option in
                UIAction(title: option, state: option == language ? .on : .off) { [weak self] _ in
                    _ = self?.textView?.inputCoordinator?.setCodeLanguage(blockID: blockID, language: option)
                }
            })
    }

    // MARK: - VoiceOver Headings rotor

    /// Every non-empty heading's text range in storage, in document order,
    /// except those folded away (VoiceOver never reaches folded content).
    /// Headings carry `accessibilityTextHeadingLevel`, so VoiceOver also
    /// announces the level when it reads them.
    func headingRanges() -> [NSRange] {
        guard let storage = textView?.textStorage else { return [] }
        var ranges: [NSRange] = []
        // One run per block (its id); the last character is its separator.
        storage.enumerateAttribute(.nativeBlockID, in: NSRange(location: 0, length: storage.length)) { id, range, _ in
            guard id != nil, range.length > 1, surface?.isHidden(atUTF16: range.location) != true,
                storage.attribute(.accessibilityTextHeadingLevel, at: range.location, effectiveRange: nil) != nil
            else { return }
            ranges.append(NSRange(location: range.location, length: range.length - 1))
        }
        return ranges
    }

    /// The system Headings rotor over the text view: each item is a heading's
    /// text range, searched from the current item (or the caret).
    lazy var headingRotor = UIAccessibilityCustomRotor(systemType: .heading) { [weak self] predicate in
        guard let self, let textView = self.textView else { return nil }
        let headings = self.headingRanges()
        let forward = predicate.searchDirection == .next
        let current = predicate.currentItem.targetRange.map {
            textView.offset(from: textView.beginningOfDocument, to: $0.start)
        }
        let target =
            forward
            ? headings.first { $0.location > (current ?? -1) }
            : headings.last { $0.location < (current ?? Int.max) }
        guard let target, let start = textView.position(from: textView.beginningOfDocument, offset: target.location),
            let end = textView.position(from: start, offset: target.length),
            let range = textView.textRange(from: start, to: end)
        else { return nil }
        return UIAccessibilityCustomRotorItemResult(targetElement: textView, targetRange: range)
    }

    // MARK: - UIGestureRecognizerDelegate (inline chip taps)

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let textView, gestureRecognizer === textView.chipTapRecognizer else { return true }
        return textView.chipTapShouldBegin(at: gestureRecognizer.location(in: textView))
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard let textView, gestureRecognizer === textView.chipTapRecognizer else { return false }
        if otherGestureRecognizer is UIPanGestureRecognizer || otherGestureRecognizer is UILongPressGestureRecognizer {
            return false
        }
        return otherGestureRecognizer.view === textView
            || (otherGestureRecognizer.view?.isDescendant(of: textView) == true)
    }
}
