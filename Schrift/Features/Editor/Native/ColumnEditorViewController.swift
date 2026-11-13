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
    /// Where the editor opens (PR12c: a find or outline result in a column):
    /// that column is active with the caret at the block's start.
    let target: (column: String, block: String)?
    /// A block a column moved or joined into another column, until that
    /// column shows it: the caret and the keys held meanwhile follow it
    /// there (PR12c). `source` is the column it left.
    @ObservationIgnored private var following: (left: NativeInputCoordinator.BlockLeft, source: NativeEditorSession)?

    init(document: NativeEditorSession, groupID: String, target: (column: String, block: String)? = nil) {
        self.document = document
        self.groupID = groupID
        self.target = target
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
        if let target, let index = group.columns.firstIndex(where: { $0.id == target.column }) {
            active = index
            place(sessions[index], at: target.block)
        }
        isLoaded = true
    }

    /// The selection in `block` of `session`, a folded toggle above it
    /// opened first (view state); a reader's text view has no input.
    private func place(_ session: NativeEditorSession, at block: String, offset: Int = 0, length: Int = 0) {
        session.surface.reveal(block)
        if let input = session.input {
            input.focus(at: block, offset: offset, length: length)
        } else if let entry = session.surface.rangeIndex.entry(for: block) {
            session.textView.selectedRange = NSRange(location: entry.textRange.location, length: 0)
        }
    }

    /// The column showing the block a column moved out, now that one does,
    /// takes the caret in it and types the held keys there. A delivery to
    /// another column that does not show it ends the wait (the block left
    /// the group, or a peer changed it first): the keys become the
    /// document's recovery entry, never typed where the block was.
    private func follow(after delivered: NativeEditorSession? = nil) {
        guard let (left, source) = following else { return }
        guard let index = columns.firstIndex(where: { $0.surface.rangeIndex.entry(for: left.blockID) != nil }) else {
            if let delivered, delivered !== source { dropFollowing() }
            return
        }
        following = nil
        active = index
        place(columns[index], at: left.blockID, offset: left.offset, length: left.length)
        columns[index].input?.adopt(left.keys)
    }

    private func dropFollowing() {
        guard let (left, source) = following else { return }
        following = nil
        source.input?.composition.recover(NativeInputCoordinator.text(of: left.keys), blockID: left.blockID)
    }

    /// One column's surface, wired to this editor.
    private func attach(_ columnID: String) async -> NativeEditorSession? {
        guard let session = await document.openColumn(group: groupID, column: columnID) else { return nil }
        session.input?.onExit = { [weak self] in self?.close() }
        session.textView.blockControls.onOpenTable = { [weak self] in self?.openTable = NativeTableRequest(id: $0) }
        // The group's own change reaches every column: its structure may have changed (PR12b).
        session.onApplied = { [weak self] delivery in
            guard let self else { return }
            self.follow(after: session)
            if self.touchesGroup(delivery) { self.scheduleReconcile() }
        }
        // shortcut: a block moved out of the group (into the document) is not
        // followed: the document is behind the editor; follow it when the
        // document can show a caret beside the group.
        session.input?.onBlockLeft = { [weak self, weak session] left in
            guard let self, let session else { return }
            self.dropFollowing()
            self.following = (left, session)
            self.follow()
        }
        if let awareness = document.awareness { session.showAwareness(awareness) }
        onAttached?(session)
        return session
    }

    private func touchesGroup(_ delivery: ReplicaDelivery) -> Bool {
        delivery.events.contains { event in
            guard case .patch(let patch, _) = event else { return false }
            return patch.changes.contains { change in
                switch change {
                case .replaceBlock(let id, _): id == groupID
                case .remove(let ids): ids.contains(groupID)
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
    /// Set by tests: before a reconcile attaches a new column, and each surface attached.
    @ObservationIgnored var beforeAttach: (() async -> Void)?
    @ObservationIgnored var onAttached: ((NativeEditorSession) -> Void)?

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
            // Surfaces attached by this pass: a close while one attaches ends them
            // all, or the group stays open and its card stops updating (PR12b review).
            var attached: [NativeEditorSession] = []
            for column in group.columns {
                if let session = byID.removeValue(forKey: column.id) {
                    next.append(session)
                } else {
                    await beforeAttach?()
                    if let session = await attach(column.id) {
                        attached.append(session)
                        next.append(session)
                    }
                    guard !isClosed else { break }
                }
            }
            guard !isClosed else {
                for session in attached { session.close() }
                break
            }
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
        return input.applyColumns(groupID, command, expecting: group?.columns.map(\.id))
    }

    /// Ends every column surface and hands focus back to the document.
    func close() {
        guard !isClosed else { return }
        dropFollowing()
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
        container.takesFocusOnOpen = model.target == nil
        container.contentSizeCategory = contentSize
        if container.labels != labels { container.labels = labels }
        container.onActivate = { [model] index in
            // Focus moved during a SwiftUI update too (the picker's column): change only what changed.
            if model.active != index { model.active = index }
        }
        container.show(
            model.columns.map(\.textView), widths: model.group?.columns.map { $0.width ?? 1 } ?? [],
            active: model.active)
    }
}

/// The column editor's text views (PR12a), laid out in one scroll (PR12c):
/// side by side at their relative widths in regular width when every column
/// gets `minimumColumnWidth` (scaled with Dynamic Type), stacked otherwise.
/// Each column's text view is a viewport of its column: framed to the part of
/// the column on screen and scrolled to match, so TextKit lays out only what
/// is visible (a column of 1,000 blocks realises a screen of it). Its own pan
/// is off; this view scrolls. A change of layout only moves frames: no view
/// leaves the hierarchy or resigns, so focus, the selection, marked text and
/// a pending prediction stay through rotation, split view and Stage Manager.
final class ColumnTextContainer: UIScrollView {
    enum Layout: Equatable { case sideBySide, stacked }

    static let spacing = DocsSpacing.spaceSM
    /// The narrowest column side by side, at the default text size.
    static let minimumColumnWidth: CGFloat = 220

    fileprivate var presentations: [ObjectIdentifier: NativeTextPresentation] = [:]
    private(set) var shown: NativeTextView?
    /// Each column's VoiceOver container, in column order.
    private(set) var frames: [ColumnFrameView] = []
    private(set) var layout: Layout = .stacked
    private var widths: [CGFloat] = []
    /// Each column's rectangle in this view's content, from the last layout.
    private var regions: [ObjectIdentifier: CGRect] = [:]
    /// The offset this view gave each text view, and the selection it last saw.
    private var offsets: [ObjectIdentifier: CGFloat] = [:]
    private var selections: [ObjectIdentifier: NSRange] = [:]
    private var placing = false
    private var revealing = false
    /// A column whose caret moved or which scrolled itself: shown after the next layout.
    private var pendingReveal: NativeTextView?
    /// The text size the columns are drawn at (the host's Dynamic Type).
    var contentSizeCategory: UIContentSizeCategory = .large {
        didSet { if contentSizeCategory != oldValue { setNeedsLayout() } }
    }
    var labels = NativeEditorLabels() {
        didSet {
            columnRotor.name = labels.columnsRotor
            relabel()
        }
    }
    /// The first column shown takes first responder (the keyboard comes up);
    /// not when the editor opened at a find result (PR12c review).
    var takesFocusOnOpen = true
    /// A column's text view became first responder (a tap): it is the active column.
    var onActivate: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        alwaysBounceVertical = true
        accessibilityCustomRotors = [columnRotor]
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (view: ColumnTextContainer, _) in
            view.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { nil }

    /// Shows `views` (one per column, in order) at `widths`, `active` the
    /// column the picker and the Column menu act on. A newly active column
    /// takes first responder when the previous one had it (the keyboard
    /// stays) and is scrolled to its caret.
    func show(_ views: [NativeTextView], widths: [Double] = [], active: Int) {
        var next: [ColumnFrameView] = []
        for view in views {
            if let frame = frames.first(where: { $0.textView === view }) {
                next.append(frame)
            } else {
                next.append(adopt(view))
            }
        }
        // A removed column's view leaves, or it would sit on top and take every touch (PR12b review).
        for frame in frames where !next.contains(where: { $0 === frame }) {
            frame.textView.onGeometry = nil
            frame.textView.onFocus = nil
            frame.removeFromSuperview()
        }
        frames = next
        self.widths = views.indices.map { index in
            let width = widths.indices.contains(index) ? widths[index] : 1
            return width.isFinite && width > 0 ? CGFloat(width) : 1
        }
        relabel()
        setNeedsLayout()
        guard views.indices.contains(active) else {
            shown = nil
            return
        }
        let target = views[active]
        guard target !== shown else { return }
        let previous = shown
        shown = target
        // First responder moves with the column: the keyboard stays.
        if previous?.isFirstResponder == true || (previous == nil && takesFocusOnOpen), target.isEditable,
            !target.isFirstResponder
        {
            _ = target.becomeFirstResponder()
        }
        layoutIfNeeded()
        reveal(target)
        UIAccessibility.post(notification: .layoutChanged, argument: target)
    }

    private func adopt(_ view: NativeTextView) -> ColumnFrameView {
        let frame = ColumnFrameView(view)
        // This view scrolls; the text view only follows it.
        view.panGestureRecognizer.isEnabled = false
        view.contentInsetAdjustmentBehavior = .never
        view.showsVerticalScrollIndicator = false
        view.alwaysBounceVertical = false
        view.scrollsToTop = false
        view.onGeometry = { [weak self, weak view] in
            guard let self, let view else { return }
            self.textViewLaidOut(view)
        }
        view.onFocus = { [weak self, weak view] in
            guard let self, let view, let index = self.frames.firstIndex(where: { $0.textView === view }) else {
                return
            }
            self.onActivate?(index)
        }
        addSubview(frame)
        return frame
    }

    private func relabel() {
        for (index, frame) in frames.enumerated() {
            frame.accessibilityLabel = String(format: labels.column, index + 1, frames.count)
        }
        accessibilityElements = frames
    }

    /// Side by side needs regular width and room for the narrowest column.
    static func layout(
        width: CGFloat, widths: [CGFloat], sizeClass: UIUserInterfaceSizeClass, contentSize: UIContentSizeCategory
    ) -> Layout {
        guard sizeClass == .regular, widths.count > 1, let narrowest = widths.min() else { return .stacked }
        let minimum = UIFontMetrics(forTextStyle: .body).scaledValue(
            for: minimumColumnWidth, compatibleWith: UITraitCollection(preferredContentSizeCategory: contentSize))
        let usable = width - spacing * CGFloat(widths.count - 1)
        return usable * narrowest / widths.reduce(0, +) >= minimum ? .sideBySide : .stacked
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        place()
        if let view = pendingReveal {
            pendingReveal = nil
            reveal(view)
        }
    }

    /// Lays the columns out and frames each text view to its column's part of the screen.
    private func place() {
        guard !frames.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
        layout = Self.layout(
            width: bounds.width, widths: widths, sizeClass: traitCollection.horizontalSizeClass,
            contentSize: contentSizeCategory)
        // A text view that has not laid out yet stands for a screen of text until it has.
        let heights = frames.map { $0.textView.contentSize.height > 0 ? $0.textView.contentSize.height : bounds.height }
        var rects: [CGRect] = []
        switch layout {
        case .sideBySide:
            let usable = bounds.width - Self.spacing * CGFloat(frames.count - 1)
            let total = widths.reduce(0, +)
            var x: CGFloat = 0
            for index in frames.indices {
                let width =
                    index == frames.count - 1 ? bounds.width - x : (usable * widths[index] / total).rounded(.down)
                rects.append(CGRect(x: x, y: 0, width: width, height: heights[index]))
                x += width + Self.spacing
            }
        case .stacked:
            var y: CGFloat = 0
            for index in frames.indices {
                rects.append(CGRect(x: 0, y: y, width: bounds.width, height: heights[index]))
                y += heights[index] + Self.spacing
            }
        }
        let size = CGSize(width: bounds.width, height: rects.map(\.maxY).max() ?? 0)
        if contentSize != size { contentSize = size }
        let visible = CGRect(x: 0, y: contentOffset.y, width: bounds.width, height: bounds.height)
        placing = true
        defer { placing = false }
        for (frame, region) in zip(frames, rects) {
            let id = ObjectIdentifier(frame.textView)
            regions[id] = region
            let viewport = Self.viewport(region, visible: visible)
            if frame.frame != viewport { frame.frame = viewport }
            let offset = CGPoint(x: 0, y: viewport.minY - region.minY)
            offsets[id] = offset.y
            if frame.textView.contentOffset != offset { frame.textView.contentOffset = offset }
            // A hairline between columns: above a stacked one, left of one side by side.
            let hairline = 1 / max(1, traitCollection.displayScale)
            frame.divider.isHidden = region.minX == 0 && region.minY == 0
            frame.divider.frame =
                layout == .stacked
                ? CGRect(x: 0, y: -offset.y - Self.spacing / 2, width: region.width, height: hairline)
                : CGRect(x: -Self.spacing / 2, y: 0, width: hairline, height: viewport.height)
            frame.divider.backgroundColor = frame.textView.blockControls.color(\.borderDefault)
        }
    }

    /// The part of `region` on screen; off screen, a screen of it (at most)
    /// at the edge nearest the screen, so the text view stays a real viewport.
    static func viewport(_ region: CGRect, visible: CGRect) -> CGRect {
        let clip = region.intersection(visible)
        if !clip.isNull, clip.height >= 1 { return clip }
        let height = min(region.height, visible.height)
        let top = min(max(visible.minY, region.minY), region.maxY - height)
        return CGRect(x: region.minX, y: top, width: region.width, height: height)
    }

    /// After one text view's layout pass: its height may have changed (lay
    /// the columns out again), it may have scrolled itself (UIKit keeping the
    /// caret visible: this view scrolls instead), or its caret moved (shown).
    private func textViewLaidOut(_ view: NativeTextView) {
        guard !placing, !revealing else { return }
        let id = ObjectIdentifier(view)
        if let region = regions[id], abs(region.height - view.contentSize.height) > 0.5 { setNeedsLayout() }
        let scrolled = offsets[id].map { abs($0 - view.contentOffset.y) > 0.5 } ?? false
        let moved = view.isFirstResponder && selections[id] != view.selectedRange
        selections[id] = view.selectedRange
        if scrolled || moved {
            if view.isFirstResponder { pendingReveal = view }
            setNeedsLayout()
        }
    }

    /// Scrolls the caret (or the selection's end) of `view` into sight. A
    /// caret off screen is where TextKit estimates it: place, lay out, place again.
    func reveal(_ view: NativeTextView) {
        let id = ObjectIdentifier(view)
        revealing = true
        defer {
            revealing = false
            selections[id] = view.selectedRange
        }
        for _ in 0..<3 {
            guard let region = regions[id], let end = view.selectedTextRange?.end else { return }
            let caret = view.caretRect(for: end)
            guard caret.minY.isFinite, caret.height.isFinite else { return }
            let before = contentOffset
            scrollRectToVisible(
                caret.offsetBy(dx: region.minX, dy: region.minY).insetBy(dx: 0, dy: -DocsSpacing.spaceBase),
                animated: false)
            guard contentOffset != before else { return }
            place()
            view.layoutIfNeeded()
        }
    }

    /// VoiceOver's Columns rotor: the next or previous column's text.
    private lazy var columnRotor = UIAccessibilityCustomRotor(name: labels.columnsRotor) { [weak self] predicate in
        guard let self else { return nil }
        let views = self.frames.map(\.textView)
        let current = predicate.currentItem.targetElement.flatMap { element in
            views.firstIndex { view in
                (element as? UIView).map { $0 === view || $0.isDescendant(of: view) } ?? false
            }
        }
        let next: Int
        if predicate.searchDirection == .next {
            next = current.map { $0 + 1 } ?? 0
        } else {
            next = current.map { $0 - 1 } ?? views.count - 1
        }
        guard views.indices.contains(next) else { return nil }
        return UIAccessibilityCustomRotorItemResult(targetElement: views[next], targetRange: nil)
    }
}

/// One column in the editor (PR12c): VoiceOver's container "Column 2 of 3"
/// around the column's text view, framed by `ColumnTextContainer`.
final class ColumnFrameView: UIView {
    let textView: NativeTextView
    /// A hairline before every column but the first.
    let divider = UIView()

    init(_ textView: NativeTextView) {
        self.textView = textView
        super.init(frame: .zero)
        accessibilityContainerType = .semanticGroup
        textView.frame = bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(textView)
        divider.isUserInteractionEnabled = false
        addSubview(divider)
    }

    required init?(coder: NSCoder) { nil }
}
