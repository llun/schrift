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
final class ColumnEditorModel: Identifiable {
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
    /// familiar (the card stays the only view of it). Once per model: the
    /// presenter owns the model, so a screen's `.task` running again (a table
    /// editor's cover dismissed over it) never attaches the columns twice.
    func load() async {
        guard !loadStarted else { return }
        loadStarted = true
        guard let group = await document.columnGroup(groupID), group.isFamiliar else {
            isLoaded = true
            return
        }
        var sessions: [NativeEditorSession] = []
        for column in group.columns {
            guard let session = await attach(column.id) else { break }
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
        relabel()
        isLoaded = true
    }

    /// One column's surface, wired to this editor.
    private func attach(_ columnID: String) async -> NativeEditorSession? {
        guard let session = await document.openColumn(group: groupID, column: columnID) else { return nil }
        session.input?.onExit = { [weak self] in self?.close() }
        session.textView.blockControls.onOpenTable = { [weak self] in self?.openTable = NativeTableRequest(id: $0) }
        // The group's own change reaches every column: its structure may have changed (PR12b).
        session.onApplied = { [weak self] delivery in
            guard let self, self.touchesGroup(delivery) else { return }
            self.scheduleReconcile()
        }
        if let awareness = document.awareness { session.showAwareness(awareness) }
        return session
    }

    private func touchesGroup(_ delivery: ReplicaDelivery) -> Bool {
        delivery.events.contains { event in
            guard case .patch(let patch, _) = event else { return false }
            return patch.changes.contains { change in
                switch change {
                case .replaceBlock(let id, _): id == groupID
                case .reset: true
                default: false
                }
            }
        }
    }

    private func relabel() {
        for (index, session) in columns.enumerated() {
            session.textView.accessibilityIdentifier = "nativeEditor.column.\(index)"
        }
    }

    // MARK: - Structure (PR12b)

    @ObservationIgnored private var reconciling = false
    @ObservationIgnored private var reconcileAgain = false
    /// Set by tests: after each reconcile.
    @ObservationIgnored var onReconciled: (() -> Void)?

    private func scheduleReconcile() {
        guard !isClosed else { return }
        if reconciling {
            reconcileAgain = true
            return
        }
        reconciling = true
        Task { await reconcile() }
    }

    /// The group as the replica holds it now, shown: a column a peer (or a
    /// command) added gets a surface, a removed one loses its own, the order
    /// follows the group's, and the shown column stays shown while it exists.
    /// A group that dissolved, went or turned unfamiliar closes the editor:
    /// the document shows what is left.
    private func reconcile() async {
        repeat {
            reconcileAgain = false
            let group = await document.columnGroup(groupID)
            guard !isClosed else { break }
            guard let group, group.isFamiliar else {
                close()
                break
            }
            let shown = activeSession?.column?.id
            var byID: [String: NativeEditorSession] = [:]
            for session in columns { if let id = session.column?.id { byID[id] = session } }
            var next: [NativeEditorSession] = []
            for column in group.columns {
                if let session = byID.removeValue(forKey: column.id) {
                    next.append(session)
                } else if let session = await attach(column.id) {
                    guard !isClosed else {
                        session.close()
                        break
                    }
                    next.append(session)
                }
            }
            guard !isClosed else { break }
            for session in byID.values {
                session.textView.resignFirstResponder()
                session.close()
            }
            self.group = group
            columns = next
            relabel()
            active = next.firstIndex { $0.column?.id == shown } ?? min(active, max(0, next.count - 1))
        } while reconcileAgain && !isClosed
        reconciling = false
        onReconciled?()
    }

    /// The shown column's structure commands, as the column menu offers them.
    enum ColumnAction: CaseIterable {
        case addLeft, addRight, moveLeft, moveRight, wider, narrower, delete
    }

    /// The command `action` is for the shown column now; nil when it is not
    /// available (an edge, the minimum width, the column bound).
    func command(_ action: ColumnAction) -> BlockNoteColumnCommand? {
        guard let group, group.columns.indices.contains(active) else { return nil }
        let count = group.columns.count
        let widths = group.columns.map { $0.width ?? 1 }
        switch action {
        case .addLeft, .addRight:
            guard count < ColumnGroup.maxColumns else { return nil }
            return .add(
                index: active + (action == .addRight ? 1 : 0), columnID: UUID().uuidString,
                paragraphID: UUID().uuidString)
        case .moveLeft: return active > 0 ? .move(from: active, to: active - 1) : nil
        case .moveRight: return active + 1 < count ? .move(from: active, to: active + 1) : nil
        case .delete: return .remove(index: active)
        case .wider, .narrower:
            // The resize handle beside the column (its right one, the last
            // column's left one), dragged by a quarter of a column, clamped as
            // `ColumnResizeExtension` clamps (no column below 0.5).
            let left = active + 1 < count ? active : active - 1
            guard left >= 0 else { return nil }
            let growsLeft = (action == .wider) == (left == active)
            let step = growsLeft ? Self.widthStep : -Self.widthStep
            var newLeft = widths[left] + step
            var newRight = widths[left + 1] - step
            let minimum = BlockNoteColumnCommand.minimumWidth
            if newLeft < minimum {
                newRight -= minimum - newLeft
                newLeft = minimum
            } else if newRight < minimum {
                newLeft -= minimum - newRight
                newRight = minimum
            }
            guard newLeft >= minimum, newRight >= minimum, newLeft != widths[left] else { return nil }
            return .resize(left: left, leftWidth: newLeft, rightWidth: newRight)
        }
    }

    /// One Wider/Narrower step: a quarter of an average column.
    static let widthStep = 0.25

    /// Applies `action` to the shown column through its input.
    @discardableResult
    func perform(_ action: ColumnAction) -> Bool {
        guard let command = command(action), let input = activeSession?.input else { return false }
        return input.applyColumns(groupID, command)
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

extension ColumnEditorModel.ColumnAction {
    var titleKey: L10nKey {
        switch self {
        case .addLeft: .native_editor_table_column_left
        case .addRight: .native_editor_table_column_right
        case .moveLeft: .native_editor_column_move_left
        case .moveRight: .native_editor_column_move_right
        case .wider: .native_editor_table_wider
        case .narrower: .native_editor_table_narrower
        case .delete: .native_editor_table_column_delete
        }
    }
}

/// The column editor's SwiftUI screen: the column picker, the shown column's
/// text, and the document's formatting bar, slash menu and link editor over
/// the shown column's input.
struct ColumnEditorScreen: View {
    /// Owned by the presenter, made when the card is tapped.
    let model: ColumnEditorModel
    let serverOrigin: String
    var isOffline = false
    @State private var linkTarget: NativeLinkTarget?
    @Environment(LocalizationStore.self) private var loc
    @Environment(\.docsTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(ImageLoader.self) private var images: ImageLoader?

    var body: some View {
        NavigationStack {
            content(model)
                .background(theme.colors.surfacePage)
                .navigationTitle(String(format: loc[.native_editor_columns], model.columns.count))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(loc[.editor_action_done]) { model.close() }
                            .accessibilityIdentifier("nativeEditor.columns.done")
                    }
                    // The shown column's structure (PR12b), as the web's handles and drop zones do it.
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            ForEach(ColumnEditorModel.ColumnAction.allCases, id: \.self) { action in
                                Button(role: action == .delete ? .destructive : nil) {
                                    model.perform(action)
                                } label: {
                                    Text(loc[action.titleKey])
                                }
                                .disabled(model.activeSession?.input == nil || model.command(action) == nil)
                                .accessibilityIdentifier("nativeEditor.columns.\(action)")
                            }
                        } label: {
                            Text(loc[.native_editor_table_column])
                        }
                        .accessibilityIdentifier("nativeEditor.columns.menu")
                        .disabled(model.activeSession?.input == nil)
                    }
                }
        }
        // Done and Escape close the model; the screen never makes or closes one itself.
        .task { await model.load() }
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
