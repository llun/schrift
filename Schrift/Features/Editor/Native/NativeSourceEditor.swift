import SwiftUI
import UIKit

/// Focused editor for a `mathBlock`, `diagram`, or inline `<math>` chip (PR14).
/// Attaches a scoped `NativeEditorSession` over the node's own `YXmlText` so live
/// Yjs merges, shared undo/redo, cursor adapters, and provisional IME recovery
/// work through the same replica machinery as the document.
@MainActor
final class NativeSourceEditorViewController: UIViewController {
    let document: NativeEditorSession
    let request: NativeSourceRequest
    var labels = NativeEditorLabels()
    var doneTitle: String = Strings_en.table[.editor_action_done] ?? "Done"
    var goneTitle: String = Strings_en.table[.native_editor_source_gone] ?? "This source is no longer in the document."
    var contentSize: UIContentSizeCategory?
    var onClose: (() -> Void)?

    private(set) var sourceSession: NativeEditorSession?
    private(set) var isLoaded = false
    private(set) var isGone = false
    private var loadStarted = false
    private var isClosed = false
    private var appliedPresentation: NativeTextPresentation?

    private let goneLabel = UILabel()

    init(document: NativeEditorSession, request: NativeSourceRequest) {
        self.document = document
        self.request = request
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(
            input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dismissFromKeyCommand))
        let done = UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(dismissFromKeyCommand))
        escape.wantsPriorityOverSystemBehavior = true
        done.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [escape, done]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "nativeEditor.source"
        if case .inlineMath = request {
            title = labels.mathSource
        }
        let doneButton = UIBarButtonItem(
            title: doneTitle,
            primaryAction: UIAction { [weak self] _ in self?.close() })
        doneButton.accessibilityIdentifier = "nativeEditor.source.done"
        navigationItem.rightBarButtonItem = doneButton

        goneLabel.translatesAutoresizingMaskIntoConstraints = false
        goneLabel.text = goneTitle
        goneLabel.textColor = .secondaryLabel
        goneLabel.font = .preferredFont(forTextStyle: .body)
        goneLabel.adjustsFontForContentSizeCategory = true
        goneLabel.numberOfLines = 0
        goneLabel.textAlignment = .center
        goneLabel.accessibilityIdentifier = "nativeEditor.source.gone"
        goneLabel.isHidden = true
        view.addSubview(goneLabel)
        NSLayoutConstraint.activate([
            goneLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            goneLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            goneLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        Task { await load() }
    }

    func load() async {
        guard !loadStarted else { return }
        loadStarted = true
        guard let session = await document.openSource(request) else {
            guard !isClosed else { return }
            showGone()
            isLoaded = true
            return
        }
        guard !isClosed else {
            session.close()
            return
        }
        sourceSession = session
        if let kind = session.source {
            title = NativeSourcePreview.editorTitle(for: kind, labels: labels)
        }
        session.input?.onExit = { [weak self] in self?.close() }
        session.input?.onDone = { [weak self] in self?.close() }
        session.onApplied = { [weak self] _ in self?.handleDelivery() }

        let textView = session.textView
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(
            top: DocsSpacing.spaceBase, left: DocsSpacing.gutter, bottom: DocsSpacing.spaceBase,
            right: DocsSpacing.gutter)
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        updatePresentation()

        if textView.isEditable {
            let end = session.surface.rangeIndex.entries.first.map { NSMaxRange($0.textRange) } ?? 0
            textView.selectedRange = NSRange(location: end, length: 0)
            session.input?.textViewDidChangeSelection(textView)
            _ = textView.becomeFirstResponder()
        } else {
            _ = becomeFirstResponder()
        }
        isLoaded = true
    }

    func updatePresentation() {
        navigationItem.rightBarButtonItem?.title = doneTitle
        goneLabel.text = goneTitle
        guard let session = sourceSession else { return }
        if let kind = session.source {
            title = NativeSourcePreview.editorTitle(for: kind, labels: labels)
        }
        session.textView.blockControls.labels = labels
        let category = contentSize ?? view.traitCollection.preferredContentSizeCategory
        let presentation = NativeTextPresentation(contentSize: category, labels: labels)
        guard appliedPresentation != presentation else { return }
        appliedPresentation = presentation
        session.surface.updatePresentation(
            traits: UITraitCollection(preferredContentSizeCategory: category), labels: labels)
    }

    private func showGone() {
        isGone = true
        goneLabel.isHidden = false
        _ = becomeFirstResponder()
    }

    private func handleDelivery() {
        guard !isClosed, let sourceSession else { return }
        if sourceSession.surface.blocks.isEmpty, sourceSession.input?.compositionOwnsView != true {
            close()
        }
    }

    @objc private func dismissFromKeyCommand() {
        close()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if let sourceSession {
            // Resign before closing so `textViewDidEndEditing` flushes any
            // unconfirmed IME composition into `provisional.json` recovery.
            sourceSession.textView.resignFirstResponder()
            if sourceSession.input?.composition.isActive == true {
                sourceSession.input?.textViewDidEndEditing(sourceSession.textView)
            }
            sourceSession.close()
            self.sourceSession = nil
        }
        if let onClose {
            onClose()
        } else if !isBeingDismissed, navigationController?.isBeingDismissed != true {
            dismiss(animated: true)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !isClosed, isBeingDismissed || navigationController?.isBeingDismissed == true else { return }
        close()
    }
}

/// SwiftUI wrapper presenting `NativeSourceEditorViewController` in a navigation controller.
struct NativeSourceEditorScreen: UIViewControllerRepresentable {
    let document: NativeEditorSession
    let request: NativeSourceRequest
    let labels: NativeEditorLabels
    let doneTitle: String
    let goneTitle: String
    var contentSize: UIContentSizeCategory = .large
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let editor = NativeSourceEditorViewController(document: document, request: request)
        editor.labels = labels
        editor.doneTitle = doneTitle
        editor.goneTitle = goneTitle
        editor.contentSize = contentSize
        editor.onClose = onClose
        return UINavigationController(rootViewController: editor)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        guard let editor = controller.topViewController as? NativeSourceEditorViewController else { return }
        editor.labels = labels
        editor.doneTitle = doneTitle
        editor.goneTitle = goneTitle
        editor.contentSize = contentSize
        editor.onClose = onClose
        editor.updatePresentation()
    }
}
