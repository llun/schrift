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
    /// coordinator's durable queue (PR13b); no queue offers no upload.
    var uploadDocumentID: UUID? = nil
    var mediaQueue: DocumentSaveCoordinator? = nil
    /// Cached title resolver for linked document chips (read-only display).
    var documentTitle: (@MainActor (UUID) -> String?)? = nil
    /// Resolves a linked document by ID before pushing onto navigation (PR13c1).
    var resolveLinkedDocument: (@MainActor (UUID) async -> Document?)? = nil
    /// Opens a resolved linked document onto the caller's navigation stack (PR13c1).
    var onOpenDocument: ((Document) -> Void)? = nil
    /// Shared page-link and `@` mention candidate source (PR13c2).
    var inlinePickerSource: NativeInlinePickerSource? = nil
    /// Whether this view owns the navigation title and standalone toolbar (`--native-typing` / unit tests).
    /// When false, `EditorView` owns the unified document chrome.
    var showsStandaloneChrome = true
    /// Optional header (`EditorDocumentHeader`) hosted in the text view's top content inset.
    var headerContent: (() -> AnyView)? = nil
    /// Optional footer (`subpagesSection`) hosted in the text view's bottom content inset.
    var footerContent: (() -> AnyView)? = nil
    /// Optional shell-owned outline state when hosted inside `EditorView`.
    var externalOutlinePresented: Binding<Bool>? = nil
    var externalOutlineFocusesFind: Binding<Bool>? = nil
    var outlineShortcutEnabled = true
    var outlineClosesOutline = false
    var onOutlineAppear: (() -> Void)? = nil
    var onOutlineDismiss: (() -> Void)? = nil
    var onScrollInteraction: (() -> Void)? = nil
    @Environment(LocalizationStore.self) private var loc
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresentingOutline = false
    @State private var outlineFocusesFind = false
    /// The app's image loader; a host without one shows image placeholders.
    @Environment(ImageLoader.self) private var images: ImageLoader?
    /// The app's video poster loader; a host without one shows clean video cards.
    @Environment(VideoPosterLoader.self) private var posters: VideoPosterLoader?
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
    /// The focused source block or inline `<math>` editor currently open (PR14).
    @State private var openSource: NativeSourceRequest?
    @State private var lastSource: NativeSourceRequest?
    @State private var uploads: NativeMediaUploads?
    @State private var linkCoordinator = NativeDocumentLinkCoordinator()

    private var outlinePresentedBinding: Binding<Bool> {
        externalOutlinePresented ?? $isPresentingOutline
    }

    private var outlineFocusesFindBinding: Binding<Bool> {
        externalOutlineFocusesFind ?? $outlineFocusesFind
    }

    private var isOutlinePresented: Bool {
        outlinePresentedBinding.wrappedValue
    }

    var body: some View {
        Group {
            if session.hasUnsupportedRoot || session.surface.blocks.isEmpty {
                if headerContent != nil || footerContent != nil {
                    ScrollView {
                        VStack(alignment: .leading, spacing: EditorBlockMetrics.blockSpacing) {
                            if let headerContent {
                                headerContent()
                            }
                            if session.hasUnsupportedRoot {
                                ContentUnavailableView(
                                    loc[.native_editor_preserved_title], systemImage: "doc.richtext",
                                    description: Text(loc[.native_editor_preserved_body]))
                            } else {
                                ContentUnavailableView(
                                    loc[.editor_empty_title], systemImage: "doc.text",
                                    description: Text(loc[.editor_empty_body]))
                            }
                            if let footerContent {
                                footerContent()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollDismissesKeyboard(.interactively)
                } else if session.hasUnsupportedRoot {
                    ContentUnavailableView(
                        loc[.native_editor_preserved_title], systemImage: "doc.richtext",
                        description: Text(loc[.native_editor_preserved_body]))
                } else {
                    ContentUnavailableView(
                        loc[.editor_empty_title], systemImage: "doc.text",
                        description: Text(loc[.editor_empty_body]))
                }
            } else {
                NativeTextCanvas(
                    session: session, contentSize: uiContentSizeCategory(for: dynamicTypeSize),
                    labels: .document(loc),
                    theme: theme, loc: loc, images: images, posters: posters, serverOrigin: serverOrigin,
                    isOffline: isOffline,
                    uploads: uploads,
                    onOpenTable: { openTable = NativeTableRequest(id: $0) },
                    onOpenColumns: { openColumns = columnEditor($0) },
                    onOpenMedia: { openMedia = NativeMediaRequest(id: $0) },
                    onOpenSource: { openSource = $0 },
                    uploadingBlocks: uploads?.uploadingBlocks ?? [], waitingUploads: uploads?.waitingBlocks ?? [],
                    failedUploads: uploads?.failedBlocks ?? [],
                    documentTitle: documentTitle,
                    onOpenDocument: { id, _ in openInlineDocument(id) },
                    inlinePickerSource: inlinePickerSource,
                    headerContent: headerContent,
                    footerContent: footerContent,
                    onScrollInteraction: onScrollInteraction
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
                    GlassEffectContainer(spacing: DocsSpacing.space2xs) {
                        VStack(spacing: 0) {
                            // The classic menu, offering only what this editor can apply;
                            // each choice is one durable type change.
                            if let query = input.slashMenuQuery {
                                SlashMenuView(query: query, available: input.slashItems) { item in
                                    input.applySlashItem(item)
                                }
                                .padding(.horizontal, DocsSpacing.gutter)
                                .padding(.bottom, DocsSpacing.space2xs)
                            } else {
                                NativeInlinePickerHost(input: input)
                            }
                            NativeFormattingBar(input: input) { linkTarget = $0 }
                        }
                    }
                }
            }
        }
        .fullScreenCover(
            item: $openTable,
            onDismiss: { [session] in
                // Back to the document, after the table (the keyboard stays up).
                if let id = lastTable { session.input?.focus(after: id) }
                flushPendingLinkedDocument()
            }
        ) { request in
            TableEditorScreen(
                document: session, tableID: request.id, labels: .document(loc),
                doneTitle: loc[.editor_action_done],
                cellLabel: { String(format: loc[.native_editor_table_cell], $0, $1) }, text: { loc[$0] },
                documentTitle: documentTitle,
                serverOrigin: serverOrigin,
                isOffline: isOffline,
                inlinePickerSource: inlinePickerSource,
                onOpenDocument: { id, _ in openInlineDocument(id) },
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
                flushPendingLinkedDocument()
            }
        ) { model in
            ColumnEditorScreen(
                model: model, serverOrigin: serverOrigin, isOffline: isOffline, uploads: uploads,
                documentTitle: documentTitle, inlinePickerSource: inlinePickerSource,
                onOpenDocument: { id, _ in openInlineDocument(id) })
        }
        .sheet(
            item: $openMedia,
            onDismiss: { flushPendingLinkedDocument() }
        ) { request in
            NativeMediaInspector(
                session: session, blockID: request.id, uploads: uploads, serverOrigin: serverOrigin,
                isOffline: isOffline, onClose: { openMedia = nil })
        }
        .sheet(
            item: $openSource,
            onDismiss: { [session] in
                if linkCoordinator.pendingDocument == nil, let request = lastSource {
                    session.input?.focus(after: request)
                }
                lastSource = nil
                flushPendingLinkedDocument()
            }
        ) { request in
            NativeSourceEditorScreen(
                document: session, request: request, labels: .document(loc),
                doneTitle: loc[.editor_action_done], goneTitle: loc[.native_editor_source_gone],
                contentSize: uiContentSizeCategory(for: dynamicTypeSize),
                onClose: {
                    lastSource = request
                    openSource = nil
                })
        }
        .onChange(of: session.input?.requestedMedia) { _, id in
            // The slash menu's new media block: its inspector uploads or links the file.
            guard let id else { return }
            session.input?.requestedMedia = nil
            openMedia = NativeMediaRequest(id: id)
        }
        .onChange(of: session.input?.requestedSource) { _, request in
            // The slash menu's new `mathBlock` or inline `<math>` chip opens immediately.
            guard let request else { return }
            session.input?.requestedSource = nil
            openSource = request
        }
        .task(id: ObjectIdentifier(session)) {
            // One uploads object per session: a reopened session (another
            // account) never inherits the previous one's.
            uploads = nil
            guard let mediaQueue else { return }
            uploads = NativeMediaUploads(scope: uploadDocumentID == nil ? nil : session.scope, queue: mediaQueue)
        }
        .nativeLinkEditing($linkTarget, input: session.input)
        .onChange(of: ObjectIdentifier(session), initial: true) { _, _ in
            session.input?.onRequestLinkEdit = { linkTarget = $0 }
        }
        .modifier(
            DocumentOutlinePresentation(
                isPresented: outlinePresentedBinding, focusesFind: outlineFocusesFindBinding.wrappedValue,
                documentTitle: title,
                blocks: session.navigation.blocks, findShortcutTitle: loc[.outline_find_placeholder],
                findShortcutEnabled: !session.hasUnsupportedRoot && outlineShortcutEnabled,
                closesOutline: outlineClosesOutline,
                onFindShortcut: { presentOutline(focusingFind: true) },
                onScroll: { target in jump(target) },
                onAppear: {
                    session.navigation.isOutlinePresented = true
                    onOutlineAppear?()
                },
                onDismiss: {
                    session.navigation.isOutlinePresented = false
                    onOutlineDismiss?()
                    if let jump = pendingColumnJump {
                        pendingColumnJump = nil
                        openColumns = columnEditor(jump.group, target: (jump.column, jump.block))
                    } else {
                        flushPendingLinkedDocument()
                    }
                },
                onSelectHeading: { jump(.block($0)) },
                onQueryMatch: { target in jump(target, deliberate: false) })
        )
        .onChange(of: isOutlinePresented) { _, presented in
            session.navigation.isOutlinePresented = presented
            if presented {
                Task { await session.navigation.refresh() }
            }
        }
        .task(id: ObjectIdentifier(session)) {
            // A result in a column opens the column editor at it; the sheet goes first.
            session.navigation.onOpenColumn = { [navigation = session.navigation] group, column, block in
                // One editor at a time: a reply arriving while one is up (a card tap) is dropped.
                guard openColumns == nil, pendingColumnJump == nil else { return navigation.columnEditorClosed() }
                let jump = ColumnJump(group: group, column: column, block: block)
                if outlinePresentedBinding.wrappedValue {
                    pendingColumnJump = jump
                    outlinePresentedBinding.wrappedValue = false
                } else {
                    openColumns = columnEditor(group, target: (column, block))
                }
            }
            if let documentID {
                session.navigation.enableReadingPosition(
                    store: readingPositions ?? ReadingPositionStore(), serverOrigin: serverOrigin,
                    documentID: documentID)
            }
            session.navigation.documentTitle = documentTitle
            await session.navigation.refresh()
            session.navigation.restore()
        }
        .onDisappear {
            linkCoordinator.cancel()
            session.navigation.persist()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.navigation.persist() }
        }
        .onChange(of: isOffline) { _, _ in
            session.input?.refreshInlinePicker()
        }
        .modifier(
            NativeStandaloneChromeModifier(
                enabled: showsStandaloneChrome,
                hasUnsupportedRoot: session.hasUnsupportedRoot,
                title: title,
                outlineTitle: loc[.outline_title],
                peers: session.awareness?.peers,
                isOffline: isOffline,
                saveStatus: saveStatus,
                saveFailureDetail: saveFailureDetail,
                saveFailureOffersRetry: saveFailureOffersRetry,
                onOutline: { presentOutline(focusingFind: false) },
                onSave: onSave
            )
        )
        .background(theme.colors.surfacePage)
    }
}

extension NativeEditorView {
    /// The column editor's model for group `groupID`, owned by this view while presented (PR12a).
    fileprivate func columnEditor(
        _ groupID: String, target: (column: String, block: String)? = nil
    ) -> ColumnEditorModel {
        let model = ColumnEditorModel(document: session, groupID: groupID, target: target)
        model.inlinePickerSource = inlinePickerSource
        model.onOpenDocument = { id, _ in openInlineDocument(id) }
        model.onClose = { [navigation = session.navigation] in
            navigation.columnEditorClosed()
            lastColumns = groupID
            openColumns = nil
        }
        return model
    }

    private func openInlineDocument(_ linkedID: UUID) {
        linkCoordinator.open(
            documentID: linkedID,
            currentDocumentID: documentID,
            resolve: resolveLinkedDocument,
            hasPresentedCover: hasPresentedNavigationCover,
            dismissCovers: dismissNavigationCovers,
            push: { document in onOpenDocument?(document) }
        )
    }

    private func flushPendingLinkedDocument() {
        linkCoordinator.flushPendingIfReady(
            hasPresentedCover: hasPresentedNavigationCover,
            push: { document in onOpenDocument?(document) }
        )
    }

    private func hasPresentedNavigationCover() -> Bool {
        openTable != nil || openColumns != nil || openMedia != nil || openSource != nil || isOutlinePresented
    }

    private func dismissNavigationCovers() {
        pendingColumnJump = nil
        lastTable = nil
        openTable = nil
        openMedia = nil
        lastSource = nil
        openSource = nil
        outlinePresentedBinding.wrappedValue = false
        if let columns = openColumns {
            columns.close()
        }
        lastColumns = nil
    }

    fileprivate func presentOutline(focusingFind: Bool) {
        outlineFocusesFindBinding.wrappedValue = focusingFind
        session.navigation.isOutlinePresented = true
        outlinePresentedBinding.wrappedValue = true
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
            diagram: loc[.native_editor_diagram], mathSource: loc[.native_editor_math_source],
            diagramSource: loc[.native_editor_diagram_source], sourceEmpty: loc[.native_editor_source_empty],
            openMathSource: loc[.native_editor_open_math_source], imageExternal: loc[.editor_image_external],
            imageExternalA11y: loc[.editor_image_external_a11y], imageOffline: loc[.editor_image_offline],
            imageFailed: loc[.editor_image_failed], videoExternal: loc[.editor_video_external],
            videoExternalA11y: loc[.editor_video_external_a11y], videoOffline: loc[.editor_video_offline],
            mediaEmpty: loc[.native_editor_media_empty],
            mediaUploading: loc[.native_editor_media_uploading],
            mediaUploadFailed: loc[.native_editor_media_upload_stopped],
            mediaUploadWaiting: loc[.native_editor_media_upload_queued],
            uploadElsewhere: loc[.native_editor_upload_elsewhere],
            chipPage: loc[.native_editor_chip_page],
            chipMention: loc[.native_editor_chip_mention],
            chipUntitled: loc[.native_editor_chip_untitled],
            openLink: loc[.native_editor_open_link],
            blockMenu: loc[.native_editor_block_actions],
            blockActions: Dictionary(
                uniqueKeysWithValues: NativeBlockAction.allCases.map { ($0, loc[$0.labelKey]) }))
    }
}

/// Keeps standalone chrome (outline toolbar item, presence bar, save status, inline navigation title)
/// enabled only for direct `NativeEditorView` fixtures outside the `EditorView` document shell.
private struct NativeStandaloneChromeModifier: ViewModifier {
    let enabled: Bool
    let hasUnsupportedRoot: Bool
    let title: String
    let outlineTitle: String
    let peers: [CollaborationPeer]?
    let isOffline: Bool
    let saveStatus: SaveStatusDisplay?
    let saveFailureDetail: String?
    let saveFailureOffersRetry: Bool
    let onOutline: () -> Void
    let onSave: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onOutline) {
                            MaterialSymbol(.subject, size: 20, scales: false)
                        }
                        .accessibilityLabel(outlineTitle)
                        .accessibilityIdentifier("nativeEditor.outline")
                        .disabled(hasUnsupportedRoot)
                    }
                    // Collaborators on the scope's live socket (PR10); stale offline.
                    if let peers, presentedPeerCount(peerCount: peers.count, isOffline: isOffline) != nil {
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
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
    }
}

private struct NativeTextCanvas: UIViewControllerRepresentable {
    let session: NativeEditorSession
    let contentSize: UIContentSizeCategory
    let labels: NativeEditorLabels
    let theme: AppTheme
    let loc: LocalizationStore
    let images: ImageLoader?
    let posters: VideoPosterLoader?
    let serverOrigin: String
    let isOffline: Bool
    var uploads: NativeMediaUploads? = nil
    let onOpenTable: (String) -> Void
    let onOpenColumns: (String) -> Void
    var onOpenMedia: ((String) -> Void)? = nil
    var onOpenSource: ((NativeSourceRequest) -> Void)? = nil
    var uploadingBlocks: Set<String> = []
    var waitingUploads: Set<String> = []
    var failedUploads: Set<String> = []
    var documentTitle: (@MainActor (UUID) -> String?)? = nil
    var onOpenDocument: ((UUID, String) -> Void)? = nil
    var inlinePickerSource: NativeInlinePickerSource? = nil
    var headerContent: (() -> AnyView)? = nil
    var footerContent: (() -> AnyView)? = nil
    var onScrollInteraction: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> NativeCanvasViewController {
        let controller = NativeCanvasViewController(textView: session.textView)
        updatePresentation(controller, coordinator: context.coordinator)
        return controller
    }

    func updateUIViewController(_ controller: NativeCanvasViewController, context: Context) {
        updatePresentation(controller, coordinator: context.coordinator)
    }

    private func updatePresentation(_ controller: NativeCanvasViewController, coordinator: Coordinator) {
        // Chrome only: neither reaches storage, so neither can write Yjs.
        session.textView.blockControls.theme = theme
        session.textView.blockControls.labels = labels
        session.textView.blockControls.images = images
        session.textView.blockControls.posters = posters
        session.textView.blockControls.serverOrigin = serverOrigin
        session.input?.serverOrigin = serverOrigin
        session.input?.mediaUploads = uploads
        session.textView.blockControls.isOffline = isOffline
        session.textView.blockControls.onOpenTable = onOpenTable
        session.textView.blockControls.onOpenColumns = onOpenColumns
        session.textView.blockControls.onOpenMedia = onOpenMedia
        session.textView.blockControls.onOpenSource = onOpenSource
        session.textView.blockControls.onOpenDocument = onOpenDocument
        session.textView.blockControls.uploadingBlocks = uploadingBlocks
        session.textView.blockControls.waitingUploads = waitingUploads
        session.textView.blockControls.failedUploads = failedUploads
        session.textView.blockControls.documentTitle = documentTitle
        session.navigation.documentTitle = documentTitle
        controller.updateAccessories(
            header: headerContent.map { AnyView($0().environment(\.docsTheme, theme).environment(loc)) },
            footer: footerContent.map { AnyView($0().environment(\.docsTheme, theme).environment(loc)) },
            onScrollInteraction: onScrollInteraction)
        coordinator.update(
            surface: session.surface, input: session.input, textView: session.textView,
            inlinePickerSource: inlinePickerSource,
            presentation: NativeTextPresentation(contentSize: contentSize, labels: labels))
    }

    @MainActor
    final class Coordinator {
        private weak var surface: NativeTextSurface?
        private var presentation: NativeTextPresentation?
        private var installedInlinePickerSource = false

        func update(
            surface: NativeTextSurface, input: NativeInputCoordinator?, textView: NativeTextView,
            inlinePickerSource: NativeInlinePickerSource?, presentation: NativeTextPresentation
        ) {
            let surfaceChanged = self.surface !== surface
            if surfaceChanged {
                installedInlinePickerSource = false
            }
            if let inlinePickerSource, !installedInlinePickerSource {
                installedInlinePickerSource = true
                if textView.selectedRange == NSRange(location: 0, length: 0), input?.activeInlineTrigger == nil {
                    input?.inlinePickerSource = inlinePickerSource
                } else {
                    Task { @MainActor [weak input] in
                        input?.inlinePickerSource = inlinePickerSource
                    }
                }
            }
            // UIViewControllerRepresentable may update while UIKit handles selection.
            // Unchanged inputs must never even request a storage reconciliation.
            guard surfaceChanged || self.presentation != presentation else { return }
            self.surface = surface
            self.presentation = presentation
            surface.updatePresentation(
                traits: UITraitCollection(preferredContentSizeCategory: presentation.contentSize),
                labels: presentation.labels)
        }
    }
}

/// Hosts `session.textView` as the single vertical scroll owner with optional header
/// (`EditorDocumentHeader`) in `contentInset.top` and footer (`subpagesSection`) in `contentInset.bottom`.
@MainActor
private final class NativeCanvasViewController: UIViewController {
    let textView: NativeTextView
    private var headerHost: UIHostingController<AnyView>?
    private var footerHost: UIHostingController<AnyView>?
    private var onScrollInteraction: (() -> Void)?
    private var didRegisterPanTarget = false
    private var didApplyInitialHeaderOffset = false

    init(textView: NativeTextView) {
        self.textView = textView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let container = UIView()
        container.backgroundColor = .clear
        textView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            textView.topAnchor.constraint(equalTo: container.topAnchor),
            textView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        textView.onGeometry = { [weak self] in
            self?.layoutAccessoryViews()
        }
        if !didRegisterPanTarget {
            didRegisterPanTarget = true
            textView.panGestureRecognizer.addTarget(self, action: #selector(handlePanGesture(_:)))
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutAccessoryViews()
    }

    func updateAccessories(header: AnyView?, footer: AnyView?, onScrollInteraction: (() -> Void)?) {
        self.onScrollInteraction = onScrollInteraction
        if let header {
            let wrapped = AnyView(
                header
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: { [weak self] _, _ in
                        Task { @MainActor [weak self] in self?.layoutAccessoryViews() }
                    }
            )
            if let headerHost {
                headerHost.rootView = wrapped
            } else {
                let host = UIHostingController(rootView: wrapped)
                host.view.backgroundColor = .clear
                addChild(host)
                textView.addSubview(host.view)
                host.didMove(toParent: self)
                headerHost = host
            }
        } else if let headerHost {
            headerHost.willMove(toParent: nil)
            headerHost.view.removeFromSuperview()
            headerHost.removeFromParent()
            self.headerHost = nil
        }

        if let footer {
            let wrapped = AnyView(
                footer
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: { [weak self] _, _ in
                        Task { @MainActor [weak self] in self?.layoutAccessoryViews() }
                    }
            )
            if let footerHost {
                footerHost.rootView = wrapped
            } else {
                let host = UIHostingController(rootView: wrapped)
                host.view.backgroundColor = .clear
                addChild(host)
                textView.addSubview(host.view)
                host.didMove(toParent: self)
                footerHost = host
            }
        } else if let footerHost {
            footerHost.willMove(toParent: nil)
            footerHost.view.removeFromSuperview()
            footerHost.removeFromParent()
            self.footerHost = nil
        }

        layoutAccessoryViews()
    }

    @objc private func handlePanGesture(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began {
            onScrollInteraction?()
        }
    }

    private func layoutAccessoryViews() {
        let width = textView.bounds.width
        guard width > 0 else { return }

        let headerHeight: CGFloat
        if let headerHost {
            let fitted = headerHost.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            headerHeight = max(0, ceil(fitted.height))
            let frame = CGRect(x: 0, y: -headerHeight, width: width, height: headerHeight)
            if headerHost.view.frame != frame {
                headerHost.view.frame = frame
            }
        } else {
            headerHeight = 0
        }

        let footerHeight: CGFloat
        if let footerHost {
            let fitted = footerHost.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            footerHeight = max(0, ceil(fitted.height))
            let contentHeight = max(0, textView.contentSize.height)
            let frame = CGRect(x: 0, y: contentHeight, width: width, height: footerHeight)
            if footerHost.view.frame != frame {
                footerHost.view.frame = frame
            }
        } else {
            footerHeight = 0
        }

        let targetInset = UIEdgeInsets(top: headerHeight, left: 0, bottom: footerHeight, right: 0)
        if textView.contentInset != targetInset {
            let previousAdjustedTop = textView.adjustedContentInset.top
            let wasAtTop =
                abs(textView.contentOffset.y + previousAdjustedTop) <= 1
                || (!didApplyInitialHeaderOffset && abs(textView.contentOffset.y) <= 1)
            textView.contentInset = targetInset
            if headerHeight > 0, !textView.isDragging, !textView.isDecelerating, wasAtTop {
                didApplyInitialHeaderOffset = true
                textView.layoutIfNeeded()
                textView.contentOffset.y = -textView.adjustedContentInset.top
            }
        } else if headerHeight > 0, !didApplyInitialHeaderOffset, !textView.isDragging, !textView.isDecelerating,
            abs(textView.contentOffset.y) <= 1
        {
            didApplyInitialHeaderOffset = true
            textView.contentOffset.y = -textView.adjustedContentInset.top
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

/// Coordinates async page-link resolution and dismiss-before-push cover gating (PR13c1).
@MainActor
final class NativeDocumentLinkCoordinator {
    private(set) var pendingDocument: Document?
    private var resolveTask: Task<Void, Never>?

    func open(
        documentID linkedID: UUID,
        currentDocumentID: UUID?,
        resolve: (@MainActor (UUID) async -> Document?)?,
        hasPresentedCover: @escaping @MainActor () -> Bool,
        dismissCovers: @escaping @MainActor () -> Void,
        push: @escaping @MainActor (Document) -> Void
    ) {
        guard
            case .openInApp(let targetID) = documentLinkAction(
                forDocumentID: linkedID, currentDocumentID: currentDocumentID),
            let resolve
        else { return }
        resolveTask?.cancel()
        pendingDocument = nil
        resolveTask = Task { @MainActor [weak self] in
            let document = await resolve(targetID)
            guard let self, !Task.isCancelled, let document else { return }
            if hasPresentedCover() {
                pendingDocument = document
                dismissCovers()
            } else {
                push(document)
            }
        }
    }

    func flushPendingIfReady(
        hasPresentedCover: () -> Bool,
        push: (Document) -> Void
    ) {
        guard !hasPresentedCover(), let document = pendingDocument else { return }
        pendingDocument = nil
        push(document)
    }

    func cancel() {
        resolveTask?.cancel()
        resolveTask = nil
        pendingDocument = nil
    }
}
