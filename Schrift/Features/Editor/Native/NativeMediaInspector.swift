import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The media block a card tap or the slash menu opened (PR13a).
struct NativeMediaRequest: Identifiable {
    let id: String
}

/// A media block's inspector (PR13a): its name, caption, width, alignment and
/// preview as BlockNote's `updateBlock` props, its file (upload a photo or a
/// file, or link a URL), opening it, and deleting the block. Every change is
/// one durable command through the document's input; a document that cannot
/// be typed, and a peer's `uploadLoader`, show the block read-only.
struct NativeMediaInspector: View {
    let session: NativeEditorSession
    let blockID: String
    let uploads: NativeMediaUploads?
    let serverOrigin: String
    let isOffline: Bool
    let onClose: () -> Void
    @Environment(LocalizationStore.self) private var loc
    @Environment(\.docsTheme) private var theme
    @Environment(\.openURL) private var openURL
    /// The app's attachment loader: a same-origin attachment opens through it
    /// (download, cache, QuickLook); a host without one offers no preview.
    @Environment(AttachmentLoader.self) private var attachments: AttachmentLoader?
    @State private var draft = NativeMediaTextDraft()
    @State private var link = ""
    @State private var linkRefused = false
    @State private var photo: PhotosPickerItem?
    @State private var isImporting = false

    /// The widths offered (BlockNote stores any: a web resize keeps its own).
    static let widths: [Int] = [240, 360, 480, 640]

    private var block: BlockSnapshot? {
        // The surface is not observable; each delivery advances the session's
        // revision, so reading it here re-renders the inspector after one.
        _ = session.revision
        return session.input?.mediaBlock(blockID)
            ?? session.surface.blocks.first { $0.id == blockID && MediaBlock.isMediaLike($0.node) }
    }

    private var isEditable: Bool {
        guard let block, session.input != nil else { return false }
        return MediaBlock.nodes.contains(block.node)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let block {
                    content(block)
                } else {
                    Text(loc[.native_media_gone]).foregroundStyle(theme.colors.textSecondary)
                        .accessibilityIdentifier("nativeMedia.gone")
                }
            }
            .navigationTitle(block.map { NativeEditorLabels.document(loc).kind($0.node) } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc[.editor_action_done]) {
                        commitText()
                        onClose()
                    }
                    .accessibilityIdentifier("nativeMedia.done")
                }
            }
        }
        .onAppear { draft.follow(block?.props ?? []) }
        // A peer's or an upload's name or caption reaches every field the user has not touched.
        .onChange(of: session.revision) { _, _ in draft.follow(block?.props ?? []) }
        .onChange(of: photo) { _, item in
            guard let item, let block else { return }
            photo = nil
            uploads?.start(
                .photo { try await item.loadTransferable(type: Data.self) }, into: blockID, slot: slot(block),
                in: session)
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: contentTypes) { result in
            guard case .success(let url) = result, let block else { return }
            uploads?.start(
                .file { try loadPickedAttachmentFile(at: url) }, into: blockID, slot: slot(block), in: session)
        }
    }

    @ViewBuilder private func content(_ block: BlockSnapshot) -> some View {
        let props = block.props
        let url = MediaBlock.string("url", in: props)
        let keys = Set((MediaBlock.schemas[block.node] ?? []).map(\.key))
        Section {
            status(block, url: url)
        }
        if isEditable {
            Section {
                // A value longer than a native edit may write (a peer's megabytes) is shown clipped, read-only.
                if draft.canEditName {
                    TextField(loc[.native_media_name], text: $draft.name)
                        .onSubmit(commitText)
                        .accessibilityIdentifier("nativeMedia.name")
                } else {
                    Text(MediaBlock.clipped(draft.name)).lineLimit(3).accessibilityIdentifier("nativeMedia.name")
                }
                if draft.canEditCaption {
                    TextField(loc[.native_media_caption], text: $draft.caption)
                        .onSubmit(commitText)
                        .accessibilityIdentifier("nativeMedia.caption")
                } else {
                    Text(MediaBlock.clipped(draft.caption)).lineLimit(3)
                        .accessibilityIdentifier("nativeMedia.caption")
                }
            }
            if keys.contains("previewWidth") || keys.contains("textAlignment") || keys.contains("showPreview") {
                Section {
                    if keys.contains("showPreview") {
                        Toggle(
                            loc[.native_media_show_preview],
                            isOn: Binding(
                                get: { MediaBlock.showsPreview(props) },
                                set: { set([ProjectedProp(key: "showPreview", value: .bool($0))]) })
                        )
                        .accessibilityIdentifier("nativeMedia.preview")
                    }
                    if keys.contains("previewWidth") {
                        Picker(
                            loc[.native_media_width],
                            selection: Binding(
                                get: {
                                    MediaBlock.displayWidth(props)
                                },
                                set: { width in
                                    set([
                                        ProjectedProp(key: "previewWidth", value: width.map { .int($0) } ?? .undefined)
                                    ])
                                })
                        ) {
                            Text(loc[.native_media_width_auto]).tag(Int?.none)
                            ForEach(widths(current: props), id: \.self) { Text("\($0) pt").tag(Int?.some($0)) }
                        }
                        .accessibilityIdentifier("nativeMedia.width")
                    }
                    if keys.contains("textAlignment") {
                        Picker(
                            loc[.native_media_alignment],
                            selection: Binding(
                                get: { MediaBlock.string("textAlignment", in: props).nonEmpty ?? "left" },
                                set: { set([ProjectedProp(key: "textAlignment", value: .string($0))]) })
                        ) {
                            Text(loc[.native_media_align_left]).tag("left")
                            Text(loc[.native_media_align_center]).tag("center")
                            Text(loc[.native_media_align_right]).tag("right")
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("nativeMedia.alignment")
                    }
                }
            }
            Section {
                if block.node == "image" {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label(loc[.native_media_upload_photo], systemImage: "photo")
                    }
                    .disabled(uploads?.canUpload(blockID) != true)
                    .accessibilityIdentifier("nativeMedia.uploadPhoto")
                }
                Button {
                    isImporting = true
                } label: {
                    Label(loc[.native_media_upload_file], systemImage: "doc")
                }
                .disabled(uploads?.canUpload(blockID) != true)
                .accessibilityIdentifier("nativeMedia.uploadFile")
                HStack {
                    TextField(loc[.native_media_link], text: $link)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(applyLink)
                        .accessibilityIdentifier("nativeMedia.link")
                    Button(loc[.native_media_link_apply], action: applyLink)
                        .disabled(link.isEmpty)
                        .accessibilityIdentifier("nativeMedia.applyLink")
                }
                if linkRefused {
                    Text(loc[.native_media_link_error]).font(.footnote).foregroundStyle(theme.colors.danger)
                }
            }
        }
        if !url.isEmpty {
            Section {
                open(url)
            }
        }
        if isEditable {
            Section {
                Button(loc[.native_editor_block_delete], role: .destructive) {
                    // The block's queued upload goes with it.
                    if session.input?.deleteMedia(blockID) == true { uploads?.discard(blockID) }
                    onClose()
                }
                .accessibilityIdentifier("nativeMedia.delete")
            }
        }
    }

    @ViewBuilder private func status(_ block: BlockSnapshot, url: String) -> some View {
        let labels = NativeEditorLabels.document(loc)
        VStack(alignment: .leading, spacing: DocsSpacing.space2xs) {
            Text(
                MediaBlock.clipped(
                    MediaBlock.string(
                        block.node == MediaBlock.uploadLoader ? "blockUploadName" : "name", in: block.props)
                ).nonEmpty ?? labels.kind(block.node)
            )
            .font(.headline)
            .lineLimit(2)
            let record = uploads?.record(blockID)
            if let record, record.failedAt != nil {
                Text(labels.mediaUploadFailed).foregroundStyle(theme.colors.danger)
                    .accessibilityIdentifier("nativeMedia.uploadFailed")
            } else if let record, uploads?.state(of: record) == .waiting {
                Label(labels.mediaUploadWaiting, systemImage: "clock")
                    .accessibilityIdentifier("nativeMedia.uploadWaiting")
                if isOffline {
                    Text(loc[.native_editor_media_upload_waiting]).font(.footnote)
                        .foregroundStyle(theme.colors.textSecondary)
                }
            } else if record != nil || uploads?.isPreparing(blockID) == true {
                Label(labels.mediaUploading, systemImage: "arrow.up.circle")
                    .accessibilityIdentifier("nativeMedia.uploading")
                if isOffline {
                    Text(loc[.native_editor_media_upload_waiting]).font(.footnote)
                        .foregroundStyle(theme.colors.textSecondary)
                }
            } else if let failure = uploads?.failure, failure.blockID == blockID {
                Text(loc[failure.key]).foregroundStyle(theme.colors.danger)
                    .accessibilityIdentifier("nativeMedia.failure")
            } else if block.node == MediaBlock.uploadLoader {
                Text(labels.uploadElsewhere)
            } else if url.isEmpty {
                Text(labels.mediaEmpty)
            } else {
                Text(MediaBlock.clipped(url)).font(.footnote).foregroundStyle(theme.colors.textSecondary).lineLimit(2)
                    .textSelection(.enabled)
            }
            if isEditable, uploads?.documentID == nil {
                Text(loc[.native_editor_media_upload_offline]).font(.footnote)
                    .foregroundStyle(theme.colors.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nativeMedia.status")
        // A failed upload's answer (PR13b): again, or let it go (the block stays empty).
        if let record = uploads?.record(blockID), record.failedAt != nil {
            Button(loc[.native_media_retry_upload]) { uploads?.retry(blockID) }
                .accessibilityIdentifier("nativeMedia.retryUpload")
            Button(loc[.native_media_discard_upload], role: .destructive) { uploads?.discard(blockID) }
                .accessibilityIdentifier("nativeMedia.discardUpload")
        }
    }

    /// A same-origin attachment opens through the attachment loader (its own
    /// origin, cache and preview rules); any other http(s) URL opens in the
    /// browser only on a tap, never fetched by the app.
    @ViewBuilder private func open(_ url: String) -> some View {
        if attachments != nil, let display = parseAttachmentLink("[file](\(url))", serverOrigin: serverOrigin) {
            AttachmentCardView(display: display, isOffline: isOffline)
        } else if let target = Self.openTarget(url) {
            Button {
                openURL(target.url)
            } label: {
                VStack(alignment: .leading) {
                    Label(loc[.native_media_open], systemImage: "arrow.up.forward.app")
                    // The host on its own line: what the tap really opens.
                    Text(target.host).font(.footnote).foregroundStyle(theme.colors.textSecondary)
                        .accessibilityIdentifier("nativeMedia.openHost")
                }
            }
            .accessibilityIdentifier("nativeMedia.open")
        }
    }

    private var contentTypes: [UTType] {
        switch block?.node {
        case "image": [.image]
        case "video": [.movie]
        case "audio": [.audio]
        case "pdf": [.pdf]
        default: [.item]
        }
    }

    private func widths(current props: [ProjectedProp]) -> [Int] {
        let current = MediaBlock.displayWidth(props)
        return (Self.widths + [current].compactMap { $0 }).reduce(into: [Int]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        .sorted()
    }

    private func slot(_ block: BlockSnapshot) -> MediaBlock.Slot {
        MediaBlock.Slot(node: block.node, url: MediaBlock.string("url", in: block.props))
    }

    /// What Open may open: only a URL a native edit could write (http(s),
    /// a host, no userinfo to disguise it), with its host to show.
    static func openTarget(_ url: String) -> (url: URL, host: String)? {
        guard MediaBlock.isAuthoredURL(url), let parsed = URL(string: url), let host = parsed.host(), !host.isEmpty
        else { return nil }
        return (parsed, host)
    }

    private func set(_ props: [ProjectedProp]) {
        session.input?.setMediaProps(blockID, props)
    }

    /// Name and caption, as one command when either changed.
    private func commitText() {
        guard isEditable, let block else { return }
        let props = draft.edits(block.props)
        guard !props.isEmpty else { return }
        // Posted, not yet stored: pending until a delivery shows it, or a peer's
        // later change of that field supersedes it (V4, W3).
        if session.input?.setMediaProps(blockID, props) == true { draft.committed(props) }
    }

    /// BlockNote's embed: the URL, and the name its last path segment
    /// (`filenameFromURL`) when that is one the block may store.
    private func applyLink() {
        let url = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEditable, let block, MediaBlock.isAuthoredURL(url) else {
            linkRefused = true
            return
        }
        linkRefused = false
        var props = [ProjectedProp(key: "url", value: .string(url))]
        let fileName = ProjectedProp(
            key: "name", value: .string(String(url.split(separator: "/", omittingEmptySubsequences: false).last ?? "")))
        if MediaBlock.isValidEdit(fileName, on: block.node) { props.append(fileName) }
        // The name field follows the block once the command is delivered (`draft.follow`).
        if session.input?.setMediaProps(blockID, props) == true { link = "" }
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

/// The inspector's name and caption fields (PR13a review F1, V4, W3): each
/// keeps the stored value it last synced to. A field the user has not touched
/// follows the block (an upload's name, a peer's caption); Done writes only the
/// fields the user changed, so it never writes a stale value back. A submitted
/// value stays pending, the field dirty, until a delivery shows it stored or a
/// peer's later change to that field supersedes it: a post that went stale is
/// written again by Done, never lost.
struct NativeMediaTextDraft: Equatable {
    var name = ""
    var caption = ""
    private(set) var baseName = ""
    private(set) var baseCaption = ""
    private(set) var pendingName: String?
    private(set) var pendingCaption: String?

    /// Whether the stored value fits a native edit (a longer one is read-only).
    var canEditName: Bool { baseName.utf16.count <= MediaBlock.maxName }
    var canEditCaption: Bool { baseCaption.utf16.count <= MediaBlock.maxCaption }

    /// Takes the block's stored values for every untouched field.
    mutating func follow(_ props: [ProjectedProp]) {
        Self.sync(&name, base: &baseName, pending: &pendingName, stored: MediaBlock.string("name", in: props))
        Self.sync(
            &caption, base: &baseCaption, pending: &pendingCaption, stored: MediaBlock.string("caption", in: props))
    }

    private static func sync(_ value: inout String, base: inout String, pending: inout String?, stored: String) {
        if let submitted = pending {
            // Not stored yet (in flight, or its post went stale): keep it dirty.
            guard stored == submitted || stored != base else { return }
            // Stored, or superseded by a peer's change of this field.
            pending = nil
            if value == submitted { value = stored }
            base = stored
            return
        }
        if value == base { value = stored }
        base = stored
    }

    /// `edits` were posted: pending until a delivery shows them (review W3).
    mutating func committed(_ edits: [ProjectedProp]) {
        for edit in edits {
            guard case .string(let value) = edit.value else { continue }
            if edit.key == "name" { pendingName = value }
            if edit.key == "caption" { pendingCaption = value }
        }
    }

    /// The fields the user changed and the block does not already hold.
    func edits(_ props: [ProjectedProp]) -> [ProjectedProp] {
        var edits: [ProjectedProp] = []
        if name != baseName, canEditName, name != MediaBlock.string("name", in: props) {
            edits.append(ProjectedProp(key: "name", value: .string(name)))
        }
        if caption != baseCaption, canEditCaption, caption != MediaBlock.string("caption", in: props) {
            edits.append(ProjectedProp(key: "caption", value: .string(caption)))
        }
        return edits
    }
}
