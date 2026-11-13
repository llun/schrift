import SwiftUI

struct NativeEditorView: View {
    let session: NativeEditorSession
    let title: String
    /// The document's server origin: image previews load only through a
    /// loader of this server's session (`MarkdownImageView.matchesSession`).
    /// Required, like the classic image sites.
    let serverOrigin: String
    /// Shown when the document is native-owned but editing is not enabled.
    /// The replica is preserved and read-only; the classic writer must not
    /// open over it.
    var preservedNotice: L10nKey? = nil
    /// The classic editor's save status, shown only while typing is enabled.
    var saveStatus: SaveStatusDisplay? = nil
    var saveFailureDetail: String? = nil
    var saveFailureOffersRetry = true
    var onSave: () -> Void = {}
    /// Offline, image previews show cached bytes and issue no request.
    var isOffline = false
    /// Where this document is remembered as read (PR10b); nil keeps no position.
    var documentID: UUID? = nil
    /// A host's own store (tests); the app's by default.
    var readingPositions: ReadingPositionStore? = nil
    /// Uploads a media block's file (PR13a): the server's id for the document
    /// (nil for one only this device knows, which cannot upload) and the
    /// upload itself; no upload offers none.
    var uploadDocumentID: UUID? = nil
    var mediaUpload: NativeMediaUploads.Upload? = nil
    @Environment(LocalizationStore.self) private var loc
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresentingOutline = false
    @State private var outlineFocusesFind = false
    /// The app's image loader; a host without one shows image placeholders.
    @Environment(ImageLoader.self) private var images: ImageLoader?
    @Environment(\.docsTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var linkTarget: NativeLinkTarget?
    /// The table whose editor is open (PR11a).
    @State private var openTable: NativeTableRequest?
    @State private var lastTable: String?
    /// The column group whose editor is open (PR12a).
    @State private var openColumns: ColumnEditorModel?
    @State private var lastColumns: String?
    /// A find or outline result in a column, opened once the outline has gone (PR12c).
    @State private var pendingColumnJump: ColumnJump?
    /// The media block whose inspector is open, and the document's uploads (PR13a).
    @State private var openMedia: NativeMediaRequest?
    @State private var uploads: NativeMediaUploads?

    var body: some View {
        Group {
            if session.hasUnsupportedRoot {
                ContentUnavailableView(
                    loc[.native_editor_preserved_title], systemImage: "doc.richtext",
                    description: Text(loc[.native_editor_preserved_body]))
            } else if session.surface.blocks.isEmpty {
                ContentUnavailableView(
                    loc[.editor_empty_title], systemImage: "doc.text",
                    description: Text(loc[.editor_empty_body]))
            } else {
                NativeTextCanvas(
                    session: session, contentSize: uiContentSizeCategory(for: dynamicTypeSize),
                    labels: .document(loc),
                    theme: theme, images: images, serverOrigin: serverOrigin, isOffline: isOffline,
                    onOpenTable: { openTable = NativeTableRequest(id: $0) },
                    onOpenColumns: { openColumns = columnEditor($0) },
                    onOpenMedia: { openMedia = NativeMediaRequest(id: $0) }, uploadingBlock: uploads?.uploading
                )
                .id(ObjectIdentifier(session))
            }
        }
        // Over the text, above the formatting bar's inset.
        .overlay(alignment: .bottom) { backToTopOffer }
        .safeAreaInset(edge: .top) {
            if let preservedNotice {
                Text(loc[preservedNotice])
                    .font(.footnote)
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DocsSpacing.gutter)
                    .padding(.vertical, DocsSpacing.spaceXS)
                    .background(theme.colors.surfacePage)
                    .accessibilityIdentifier("nativeEditor.preservedNotice")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let input = session.input, let recovery = input.composition.pendingRecoveries.first {
                    recoveryBanner(recovery, input: input)
                }
                if openMedia == nil, let failure = uploads?.failure {
                    Text(loc[failure.key])
                        .font(.footnote)
                        .padding()
                        .accessibilityIdentifier("nativeEditor.mediaNotice")
                }
                if let key = session.input?.noticeKey {
                    Text(loc[key])
                        .font(.footnote)
                        .padding()
                        .accessibilityIdentifier("nativeEditor.inputNotice")
                }
                if let input = session.input {
                    // The classic menu, offering only what this editor can apply;
                    // each choice is one durable type change.
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
            item: $openTable,
            onDismiss: { [session] in
                // Back to the document, after the table (the keyboard stays up).
                if let id = lastTable { session.input?.focus(after: id) }
            }
        ) { request in
            TableEditorScreen(
                document: session, tableID: request.id, labels: NativeEditorLabels(table: loc[.native_editor_table]),
                doneTitle: loc[.editor_action_done],
                cellLabel: { String(format: loc[.native_editor_table_cell], $0, $1) }, text: { loc[$0] },
                onClose: {
                    lastTable = request.id
                    openTable = nil
                }
            )
            .ignoresSafeArea()
        }
        .fullScreenCover(
            item: $openColumns,
            onDismiss: { [session] in
                // Back to the document, after the group (the keyboard stays up).
                if let id = lastColumns { session.input?.focus(after: id) }
            }
        ) { model in
            ColumnEditorScreen(model: model, serverOrigin: serverOrigin, isOffline: isOffline, uploads: uploads)
        }
        .sheet(item: $openMedia) { request in
            NativeMediaInspector(
                session: session, blockID: request.id, uploads: uploads, serverOrigin: serverOrigin,
                isOffline: isOffline, onClose: { openMedia = nil })
        }
        .onChange(of: session.input?.requestedMedia) { _, id in
            // The slash menu's new media block: its inspector uploads or links the file.
            guard let id else { return }
            session.input?.requestedMedia = nil
            openMedia = NativeMediaRequest(id: id)
        }
        .onChange(of: isOffline) { _, _ in uploads?.isOffline = { [isOffline] in isOffline } }
        .task(id: ObjectIdentifier(session)) {
            guard let mediaUpload, uploads == nil else { return }
            uploads = NativeMediaUploads(
                documentID: uploadDocumentID, serverOrigin: serverOrigin,
                isOffline: { [isOffline] in isOffline }, upload: mediaUpload)
        }
        .nativeLinkEditing($linkTarget, input: session.input)
        .modifier(
            DocumentOutlinePresentation(
                isPresented: $isPresentingOutline, focusesFind: outlineFocusesFind, documentTitle: title,
                blocks: session.navigation.blocks, findShortcutTitle: loc[.outline_find_placeholder],
                findShortcutEnabled: !session.hasUnsupportedRoot, closesOutline: false,
                onFindShortcut: { presentOutline(focusingFind: true) },
                onScroll: { target in jump(target) }, onAppear: { session.navigation.isOutlinePresented = true },
                onDismiss: {
                    session.navigation.isOutlinePresented = false
                    if let jump = pendingColumnJump {
                        pendingColumnJump = nil
                        openColumns = columnEditor(jump.group, target: (jump.column, jump.block))
                    }
                },
                onSelectHeading: { jump(.block($0)) },
                onQueryMatch: { target in jump(target, deliberate: false) })
        )
        .task(id: ObjectIdentifier(session)) {
            // A result in a column opens the column editor at it; the sheet goes first.
            session.navigation.onOpenColumn = { [navigation = session.navigation] group, column, block in
                // One editor at a time: a reply arriving while one is up (a card tap) is dropped.
                guard openColumns == nil, pendingColumnJump == nil else { return navigation.columnEditorClosed() }
                let jump = ColumnJump(group: group, column: column, block: block)
                if isPresentingOutline {
                    pendingColumnJump = jump
                    isPresentingOutline = false
                } else {
                    openColumns = columnEditor(group, target: (column, block))
                }
            }
            if let documentID {
                session.navigation.enableReadingPosition(
                    store: readingPositions ?? ReadingPositionStore(), serverOrigin: serverOrigin,
                    documentID: documentID)
            }
            await session.navigation.refresh()
            session.navigation.restore()
        }
        .onDisappear { session.navigation.persist() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.navigation.persist() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentOutline(focusingFind: false)
                } label: {
                    MaterialSymbol(.subject, size: 20, scales: false)
                }
                .accessibilityLabel(loc[.outline_title])
                .accessibilityIdentifier("nativeEditor.outline")
                .disabled(session.hasUnsupportedRoot)
            }
            // Collaborators on the scope's live socket (PR10); stale offline.
            if let peers = session.awareness?.peers,
                presentedPeerCount(peerCount: peers.count, isOffline: isOffline) != nil
            {
                ToolbarItem(placement: .topBarTrailing) {
                    PresenceBar(peers: peers).accessibilityIdentifier("nativeEditor.presence")
                }
            }
            if let saveStatus, saveStatus != .none {
                ToolbarItem(placement: .topBarTrailing) {
                    SaveStatusIndicator(
                        display: saveStatus, failureDetail: saveFailureDetail,
                        failureOffersRetry: saveFailureOffersRetry, onTap: onSave)
                }
            }
        }
        .background(theme.colors.surfacePage)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension NativeEditorView {
    /// The column editor's model for group `groupID`, owned by this view while presented (PR12a).
    fileprivate func columnEditor(
        _ groupID: String, target: (column: String, block: String)? = nil
    ) -> ColumnEditorModel {
        let model = ColumnEditorModel(document: session, groupID: groupID, target: target)
        model.onClose = { [navigation = session.navigation] in
            navigation.columnEditorClosed()
            lastColumns = groupID
            openColumns = nil
        }
        return model
    }

    fileprivate func presentOutline(focusingFind: Bool) {
        outlineFocusesFind = focusingFind
        session.navigation.isOutlinePresented = true
        isPresentingOutline = true
        Task { await session.navigation.refresh() }
    }

    /// A heading, a find match or the title: the reader chose where to be.
    fileprivate func jump(_ target: EditorScrollTarget, deliberate: Bool = true) {
        session.navigation.noteDeliberateJump()
        Task { await session.navigation.jump(to: target, deliberate: deliberate) }
    }

    /// The classic offer after a restore, over the native text.
    @ViewBuilder fileprivate var backToTopOffer: some View {
        ZStack {
            if session.navigation.reading?.offersBackToTop == true {
                BackToTopPill(title: loc[.editor_back_to_top], accessibilityLabel: loc[.editor_back_to_top_a11y]) {
                    session.navigation.backToTop()
                }
                .padding(.bottom, DocsSpacing.spaceBase)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .accessibilityIdentifier("nativeEditor.backToTop")
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: session.navigation.reading?.offersBackToTop)
    }

    /// Uncommitted IME text is never inserted silently: the user chooses.
    fileprivate func recoveryBanner(_ recovery: ProvisionalRecovery, input: NativeInputCoordinator) -> some View {
        VStack(alignment: .leading, spacing: DocsSpacing.spaceXS) {
            Text(
                loc[
                    recovery.state == .orphaned
                        ? .native_editor_composition_orphaned : .native_editor_recovery_interrupted]
            )
            .font(.footnote)
            .foregroundStyle(theme.colors.textSecondary)
            Text(recovery.text)
                .font(.body)
                .lineLimit(3)
                .accessibilityIdentifier("nativeEditor.recovery.text")
            HStack(spacing: DocsSpacing.spaceSM) {
                Button(loc[.native_editor_recovery_insert]) { input.insertRecovery(recovery) }
                    .accessibilityIdentifier("nativeEditor.recovery.insert")
                Button(loc[.native_editor_recovery_copy]) { input.copyRecovery(recovery) }
                    .accessibilityIdentifier("nativeEditor.recovery.copy")
                Spacer()
                Button(loc[.native_editor_recovery_discard], role: .destructive) { input.discardRecovery(recovery) }
                    .accessibilityIdentifier("nativeEditor.recovery.discard")
            }
            .font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DocsSpacing.gutter)
        .padding(.vertical, DocsSpacing.spaceSM)
        .background(theme.colors.surfacePage)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeEditor.recovery")
    }
}

/// Where a find or outline result in a column opens the column editor (PR12c).
private struct ColumnJump {
    var group: String
    var column: String
    var block: String
}

/// The native editor's formatting bar: the classic bar's tokens and labels
/// over the selection's marks. Each action is at most one durable command.
struct NativeFormattingBar: View {
    let input: NativeInputCoordinator
    let editLink: (NativeLinkTarget) -> Void
    @Environment(LocalizationStore.self) private var loc
    @Environment(\.docsTheme) private var theme
    @State private var showsBlockMenu = false

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DocsSpacing.space4xs) {
                // The block menu first: it acts on the block, the rest on text.
                button(id: "block", label: loc[.native_editor_block_actions], isOn: false) {
                    showsBlockMenu = true
                } glyph: {
                    MaterialSymbol(.more_horiz, size: 20, scales: false)
                }
                .popover(isPresented: $showsBlockMenu) {
                    NativeBlockMenu(input: input) { showsBlockMenu = false }
                }
                toggle("bold", label: .editor_format_bold) { MaterialSymbol(.format_bold, size: 20, scales: false) }
                toggle("italic", label: .editor_format_italic) {
                    MaterialSymbol(.format_italic, size: 20, scales: false)
                }
                toggle("underline", label: .native_editor_format_underline) { Text(verbatim: "U").underline() }
                toggle("strike", label: .native_editor_format_strike) { Text(verbatim: "S").strikethrough() }
                toggle("code", label: .native_editor_format_code) {
                    MaterialSymbol(.data_object, size: 20, scales: false)
                }
                button(id: NativeMark.link, label: loc[.editor_format_link], isOn: isOn(NativeMark.link)) {
                    if let target = input.linkTarget() { editLink(target) }
                } glyph: {
                    MaterialSymbol(.link, size: 20, scales: false)
                }
                colors(NativeMark.textColor, label: .native_editor_format_text_color) {
                    Text(verbatim: "A")
                }
                colors(NativeMark.backgroundColor, label: .native_editor_format_background_color) {
                    Text(verbatim: "A").padding(.horizontal, 4).background(theme.colors.brandFillSubtle)
                }
                button(id: "outdent", label: loc[.editor_format_outdent], isOn: false, action: { input.outdent() }) {
                    MaterialSymbol(.format_indent_decrease, size: 20, scales: false)
                }
                button(id: "indent", label: loc[.editor_format_indent], isOn: false, action: { input.indent() }) {
                    MaterialSymbol(.format_indent_increase, size: 20, scales: false)
                }
            }
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, DocsSpacing.space2xs)
        .padding(.vertical, DocsSpacing.space3xs)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, DocsSpacing.gutter)
        .padding(.bottom, DocsSpacing.space2xs)
    }

    private func isOn(_ key: String) -> Bool { input.activeMarks.contains { $0.key == key } }

    private func toggle(_ key: String, label: L10nKey, @ViewBuilder glyph: () -> some View) -> some View {
        button(id: key, label: loc[label], isOn: isOn(key), action: { input.toggleMark(key) }, glyph: glyph)
    }

    private func colors(_ key: String, label: L10nKey, @ViewBuilder glyph: () -> some View) -> some View {
        Menu {
            Button(loc[.native_editor_color_default]) { input.setColor(key, name: nil) }
            ForEach(NativeMark.colors, id: \.self) { name in
                Button(loc[Self.colorLabels[name] ?? .native_editor_color_default]) { input.setColor(key, name: name) }
            }
        } label: {
            circle(isOn: isOn(key), glyph: glyph)
        }
        .accessibilityLabel(loc[label])
        .accessibilityIdentifier("nativeEditor.format.\(key)")
    }

    private func button(
        id: String, label: String, isOn: Bool, action: @escaping () -> Void, @ViewBuilder glyph: () -> some View
    ) -> some View {
        Button(action: action) { circle(isOn: isOn, glyph: glyph) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(isOn ? .isSelected : [])
            .accessibilityIdentifier("nativeEditor.format.\(id)")
    }

    /// The classic bar's 44pt circle; the brand fill marks a mark that is on.
    private func circle(isOn: Bool, @ViewBuilder glyph: () -> some View) -> some View {
        glyph()
            .font(DocsFont.body.weight(.semibold))
            .frame(width: DocsSpacing.rowMinHeight, height: DocsSpacing.rowMinHeight)
            .foregroundStyle(isOn ? theme.colors.textBrand : theme.colors.textPrimary)
            .background(isOn ? theme.colors.brandFillSubtle : .clear)
            .clipShape(Circle())
            .contentShape(Circle())
    }

    private static let colorLabels: [String: L10nKey] = [
        "gray": .native_editor_color_gray, "brown": .native_editor_color_brown, "red": .native_editor_color_red,
        "orange": .native_editor_color_orange, "yellow": .native_editor_color_yellow,
        "green": .native_editor_color_green, "blue": .native_editor_color_blue,
        "purple": .native_editor_color_purple, "pink": .native_editor_color_pink,
    ]
}

/// The block menu (PR06d): the caret block's actions, worked out when it is
/// shown; an action the engine would refuse is disabled. Each is at most one
/// durable command.
private struct NativeBlockMenu: View {
    let input: NativeInputCoordinator
    let dismiss: () -> Void
    @Environment(LocalizationStore.self) private var loc
    @Environment(\.docsTheme) private var theme

    var body: some View {
        let available = Set(input.availableBlockActions())
        VStack(alignment: .leading, spacing: 0) {
            ForEach(NativeBlockAction.allCases, id: \.self) { action in
                row(action, isAvailable: available.contains(action))
            }
        }
        .padding(.horizontal, DocsSpacing.spaceBase)
        .padding(.vertical, DocsSpacing.space2xs)
        .presentationCompactAdaptation(.popover)
    }

    private func row(_ action: NativeBlockAction, isAvailable: Bool) -> some View {
        Button(role: action == .delete ? .destructive : nil) {
            dismiss()
            input.performBlockAction(action)
        } label: {
            Text(loc[action.labelKey])
                .font(DocsFont.body)
                .frame(maxWidth: .infinity, minHeight: DocsSpacing.rowMinHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isAvailable ? theme.colors.textPrimary : theme.colors.textTertiary)
        .disabled(!isAvailable)
        .accessibilityIdentifier("nativeEditor.block.\(action.rawValue)")
    }
}

extension NativeEditorLabels {
    /// The document's labels, localized: every native text view's chrome
    /// (the document's and, PR12a, each column's).
    @MainActor static func document(_ loc: LocalizationStore) -> NativeEditorLabels {
        NativeEditorLabels(
            preservedBlock: loc[.native_editor_preserved_block],
            unknownBlock: loc[.native_editor_unknown_block],
            pageBreak: loc[.native_editor_page_break], codeLanguage: loc[.native_editor_code_language],
            markDone: loc[.editor_checklist_done_a11y], markNotDone: loc[.editor_checklist_not_done_a11y],
            done: loc[.editor_checklist_state_done_a11y],
            notDone: loc[.editor_checklist_state_not_done_a11y], toggle: loc[.native_editor_toggle],
            expanded: loc[.native_editor_toggle_expanded],
            collapsed: loc[.native_editor_toggle_collapsed], peerCursor: loc[.native_editor_peer_cursor],
            peerSelection: loc[.native_editor_peer_selection], peerFolded: loc[.native_editor_peer_folded],
            named: loc[.native_editor_attachment_named],
            image: loc[.editor_image_a11y], video: loc[.native_editor_video],
            audio: loc[.native_editor_audio], file: loc[.native_editor_file], pdf: loc[.native_editor_pdf],
            table: loc[.native_editor_table], tableMore: loc[.native_editor_table_more],
            columns: loc[.native_editor_columns], column: loc[.native_editor_column],
            columnsRotor: loc[.native_editor_columns_rotor], math: loc[.native_editor_math],
            diagram: loc[.native_editor_diagram], imageExternal: loc[.editor_image_external],
            imageExternalA11y: loc[.editor_image_external_a11y], imageOffline: loc[.editor_image_offline],
            imageFailed: loc[.editor_image_failed], mediaEmpty: loc[.native_editor_media_empty],
            mediaUploading: loc[.native_editor_media_uploading], uploadElsewhere: loc[.native_editor_upload_elsewhere],
            blockMenu: loc[.native_editor_block_actions],
            blockActions: Dictionary(
                uniqueKeysWithValues: NativeBlockAction.allCases.map { ($0, loc[$0.labelKey]) }))
    }
}

private struct NativeTextCanvas: UIViewRepresentable {
    let session: NativeEditorSession
    let contentSize: UIContentSizeCategory
    let labels: NativeEditorLabels
    let theme: AppTheme
    let images: ImageLoader?
    let serverOrigin: String
    let isOffline: Bool
    let onOpenTable: (String) -> Void
    let onOpenColumns: (String) -> Void
    var onOpenMedia: ((String) -> Void)? = nil
    var uploadingBlock: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> NativeTextView {
        updatePresentation(context.coordinator)
        return session.textView
    }

    func updateUIView(_ view: NativeTextView, context: Context) {
        updatePresentation(context.coordinator)
    }

    private func updatePresentation(_ coordinator: Coordinator) {
        // Chrome only: neither reaches storage, so neither can write Yjs.
        session.textView.blockControls.theme = theme
        session.textView.blockControls.labels = labels
        session.textView.blockControls.images = images
        session.textView.blockControls.serverOrigin = serverOrigin
        session.textView.blockControls.isOffline = isOffline
        session.textView.blockControls.onOpenTable = onOpenTable
        session.textView.blockControls.onOpenColumns = onOpenColumns
        session.textView.blockControls.onOpenMedia = onOpenMedia
        session.textView.blockControls.uploadingBlock = uploadingBlock
        coordinator.update(
            surface: session.surface, presentation: NativeTextPresentation(contentSize: contentSize, labels: labels))
    }

    @MainActor
    final class Coordinator {
        private weak var surface: NativeTextSurface?
        private var presentation: NativeTextPresentation?

        func update(surface: NativeTextSurface, presentation: NativeTextPresentation) {
            // UIViewRepresentable may update while UIKit handles selection.
            // Unchanged inputs must never even request a storage reconciliation.
            guard self.surface !== surface || self.presentation != presentation else { return }
            self.surface = surface
            self.presentation = presentation
            surface.updatePresentation(
                traits: UITraitCollection(preferredContentSizeCategory: presentation.contentSize),
                labels: presentation.labels)
        }
    }
}

/// The link editor over a native input: the document's and a column's (PR12a).
extension View {
    func nativeLinkEditing(_ target: Binding<NativeLinkTarget?>, input: NativeInputCoordinator?) -> some View {
        sheet(item: target) { link in
            LinkEditorSheet(
                request: EditorViewModel.LinkEditorRequest(
                    blockID: UUID(),
                    span: link.href.map {
                        InlineLinkSpan(range: link.range, labelRange: link.range, label: link.label, url: $0)
                    },
                    label: link.label, url: link.href ?? "", range: link.range),
                onSave: { label, url in
                    guard input?.applyLink(label: label, url: url, to: link) == true else { return false }
                    target.wrappedValue = nil
                    return true
                },
                onRemove: {
                    input?.removeLink(link)
                    target.wrappedValue = nil
                },
                onCancel: { target.wrappedValue = nil })
        }
    }
}

/// The table editor's subject (PR11a).
struct NativeTableRequest: Identifiable {
    let id: String
}
