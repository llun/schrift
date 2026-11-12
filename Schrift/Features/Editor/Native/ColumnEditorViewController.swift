import SwiftUI
import UIKit

/// The native column editor (PR12a): one column group's columns over the
/// document, each column's blocks edited by the document's own machinery.
/// Every column is its own leased surface (`NativeEditorSession.openColumn`),
/// all attached when the editor opens, so moving between columns is view
/// state: the next column's text view becomes first responder before the
/// shown one hides, and the keyboard stays up. Typing, structure, marks, IME,
/// undo, prediction, barriers, offline journaling and live deliveries are the
/// document's, unchanged; a move that would cross a column's edge (the web's
/// Backspace into the previous column, a block out of the group) writes
/// nothing until PR12b. A table in a column opens PR11's table editor over
/// that column's surface. A reader or a read-only document gets the same
/// columns without input.
@MainActor @Observable
final class ColumnEditorModel {
    let groupID: String
    @ObservationIgnored let document: NativeEditorSession
    private(set) var group: ColumnGroup?
    /// One surface per column, in column order.
    private(set) var columns: [NativeEditorSession] = []
    /// The shown column.
    var active = 0 {
        didSet { if !columns.indices.contains(active) { active = oldValue } }
    }
    /// Set once every column is attached (tests wait for it).
    private(set) var isLoaded = false
    private(set) var isClosed = false
    /// A table card in the shown column was tapped.
    var openTable: NativeTableRequest?
    /// The table the shown column last opened: its caret goes after it.
    @ObservationIgnored var lastTable: String?
    /// The editor closed: the document takes focus back after the group.
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored private var loadStarted = false

    init(document: NativeEditorSession, groupID: String) {
        self.document = document
        self.groupID = groupID
    }

    var activeSession: NativeEditorSession? { columns.indices.contains(active) ? columns[active] : nil }

    /// Attaches every column of the group; nothing when the group is not
    /// familiar (the card stays the only view of it).
    func load() async {
        guard !loadStarted else { return }
        loadStarted = true
        guard let group = await document.columnGroup(groupID), group.isFamiliar else {
            isLoaded = true
            return
        }
        var sessions: [NativeEditorSession] = []
        for (index, column) in group.columns.enumerated() {
            guard let session = await document.openColumn(group: groupID, column: column.id) else { break }
            session.textView.accessibilityIdentifier = "nativeEditor.column.\(index)"
            session.input?.onExit = { [weak self] in self?.close() }
            session.textView.blockControls.onOpenTable = { [weak self] in self?.openTable = NativeTableRequest(id: $0) }
            if let awareness = document.awareness { session.showAwareness(awareness) }
            sessions.append(session)
        }
        // Closed while attaching, or a column the replica refused (a peer
        // changed the group meanwhile): end what attached.
        guard !isClosed, sessions.count == group.columns.count else {
            for session in sessions { session.close() }
            isLoaded = true
            if !isClosed { close() }
            return
        }
        self.group = group
        columns = sessions
        isLoaded = true
    }

    /// Ends every column surface and hands focus back to the document.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        for session in columns {
            session.textView.resignFirstResponder()
            session.close()
        }
        columns = []
        onClose?()
    }
}

/// The column editor's SwiftUI screen: the column picker, the shown column's
/// text, and the document's formatting bar, slash menu and link editor over
/// the shown column's input.
struct ColumnEditorScreen: View {
    let document: NativeEditorSession
    let groupID: String
    let serverOrigin: String
    var isOffline = false
    let onClose: () -> Void
    @State private var model: ColumnEditorModel?
    @State private var linkTarget: NativeLinkTarget?
    @Environment(LocalizationStore.self) private var loc
    @Environment(\.docsTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(ImageLoader.self) private var images: ImageLoader?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    Color.clear
                }
            }
            .background(theme.colors.surfacePage)
            .navigationTitle(String(format: loc[.native_editor_columns], model?.columns.count ?? 0))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(loc[.editor_action_done]) { model?.close() }
                        .accessibilityIdentifier("nativeEditor.columns.done")
                }
            }
        }
        .task {
            let model = ColumnEditorModel(document: document, groupID: groupID)
            model.onClose = onClose
            self.model = model
            await model.load()
        }
        // A table editor over the column covers this screen: only a dismissal closes it.
        .onDisappear { if model?.openTable == nil { model?.close() } }
    }

    @ViewBuilder private func content(_ model: ColumnEditorModel) -> some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if model.columns.count > 1 {
                Picker(loc[.native_editor_columns], selection: $model.active) {
                    ForEach(model.columns.indices, id: \.self) { index in
                        Text("\(index + 1)")
                            .accessibilityLabel(
                                String(format: loc[.native_editor_column], index + 1, model.columns.count)
                            )
                            .tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, DocsSpacing.gutter)
                .padding(.vertical, DocsSpacing.spaceXS)
                .accessibilityIdentifier("nativeEditor.columns.picker")
            }
            ColumnTextHost(
                model: model, contentSize: uiContentSizeCategory(for: dynamicTypeSize), labels: .document(loc),
                theme: theme, images: images, serverOrigin: serverOrigin, isOffline: isOffline)
        }
        .safeAreaInset(edge: .bottom) {
            if let input = model.activeSession?.input {
                VStack(spacing: 0) {
                    if let key = input.noticeKey {
                        Text(loc[key])
                            .font(.footnote)
                            .padding()
                            .accessibilityIdentifier("nativeEditor.inputNotice")
                    }
                    if let query = input.slashMenuQuery {
                        SlashMenuView(query: query, available: NativeInputCoordinator.slashItems) { item in
                            input.applySlashItem(item)
                        }
                        .padding(.horizontal, DocsSpacing.gutter)
                        .padding(.bottom, DocsSpacing.space2xs)
                    }
                    NativeFormattingBar(input: input) { linkTarget = $0 }
                }
            }
        }
        .fullScreenCover(
            item: $model.openTable,
            onDismiss: { [model] in
                // Back to the column, after the table (the keyboard stays up).
                if let id = model.lastTable { model.activeSession?.input?.focus(after: id) }
            }
        ) { request in
            if let session = model.activeSession {
                TableEditorScreen(
                    document: session, tableID: request.id,
                    labels: NativeEditorLabels(table: loc[.native_editor_table]), doneTitle: loc[.editor_action_done],
                    cellLabel: { String(format: loc[.native_editor_table_cell], $0, $1) }, text: { loc[$0] },
                    onClose: {
                        model.lastTable = request.id
                        model.openTable = nil
                    }
                )
                .ignoresSafeArea()
            }
        }
        .nativeLinkEditing($linkTarget, input: model.activeSession?.input)
    }
}

/// Every column's text view in one container; only the shown column's is
/// visible. Switching hands first responder over before hiding the old one.
private struct ColumnTextHost: UIViewRepresentable {
    let model: ColumnEditorModel
    let contentSize: UIContentSizeCategory
    let labels: NativeEditorLabels
    let theme: AppTheme
    let images: ImageLoader?
    let serverOrigin: String
    let isOffline: Bool

    func makeUIView(context: Context) -> ColumnTextContainer {
        let container = ColumnTextContainer()
        update(container)
        return container
    }

    func updateUIView(_ container: ColumnTextContainer, context: Context) {
        update(container)
    }

    private func update(_ container: ColumnTextContainer) {
        for session in model.columns {
            // Chrome only: neither reaches storage, so neither can write Yjs.
            session.textView.blockControls.theme = theme
            session.textView.blockControls.labels = labels
            session.textView.blockControls.images = images
            session.textView.blockControls.serverOrigin = serverOrigin
            session.textView.blockControls.isOffline = isOffline
            let presentation = NativeTextPresentation(contentSize: contentSize, labels: labels)
            if container.presentations[ObjectIdentifier(session)] != presentation {
                container.presentations[ObjectIdentifier(session)] = presentation
                session.surface.updatePresentation(
                    traits: UITraitCollection(preferredContentSizeCategory: contentSize), labels: labels)
            }
        }
        container.show(model.columns.map(\.textView), active: model.active)
    }
}

/// The column editor's text views (PR12a).
final class ColumnTextContainer: UIView {
    fileprivate var presentations: [ObjectIdentifier: NativeTextPresentation] = [:]
    private(set) var shown: NativeTextView?

    func show(_ views: [NativeTextView], active: Int) {
        for view in views where view.superview !== self {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        guard views.indices.contains(active) else { return }
        let next = views[active]
        guard next !== shown else { return }
        let previous = shown
        next.isHidden = false
        // First responder moves before the old view hides: the keyboard stays.
        if previous?.isFirstResponder == true || previous == nil, next.isEditable { next.becomeFirstResponder() }
        for view in views where view !== next { view.isHidden = true }
        shown = next
        UIAccessibility.post(notification: .screenChanged, argument: next)
    }
}
