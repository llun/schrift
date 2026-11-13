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
    @State private var name = ""
    @State private var caption = ""
    @State private var link = ""
    @State private var linkRefused = false
    @State private var photo: PhotosPickerItem?
    @State private var isImporting = false
    @State private var loaded = false

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
        .onAppear(perform: load)
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
                TextField(loc[.native_media_name], text: $name)
                    .onSubmit(commitText)
                    .accessibilityIdentifier("nativeMedia.name")
                TextField(loc[.native_media_caption], text: $caption)
                    .onSubmit(commitText)
                    .accessibilityIdentifier("nativeMedia.caption")
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
                                    MediaBlock.number(props.last { $0.key == "previewWidth" }?.value).map(Int.init)
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
                    .disabled(uploads?.canUpload != true)
                    .accessibilityIdentifier("nativeMedia.uploadPhoto")
                }
                Button {
                    isImporting = true
                } label: {
                    Label(loc[.native_media_upload_file], systemImage: "doc")
                }
                .disabled(uploads?.canUpload != true)
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
                    session.input?.deleteMedia(blockID)
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
                MediaBlock.string(block.node == MediaBlock.uploadLoader ? "blockUploadName" : "name", in: block.props)
                    .nonEmpty ?? labels.kind(block.node)
            )
            .font(.headline)
            if uploads?.uploading == blockID {
                Label(labels.mediaUploading, systemImage: "arrow.up.circle")
                    .accessibilityIdentifier("nativeMedia.uploading")
            } else if let failure = uploads?.failure, failure.blockID == blockID {
                Text(loc[failure.key]).foregroundStyle(theme.colors.danger)
                    .accessibilityIdentifier("nativeMedia.failure")
            } else if block.node == MediaBlock.uploadLoader {
                Text(labels.uploadElsewhere)
            } else if url.isEmpty {
                Text(labels.mediaEmpty)
            } else {
                Text(url).font(.footnote).foregroundStyle(theme.colors.textSecondary).lineLimit(2)
                    .textSelection(.enabled)
            }
            if isEditable, isOffline || uploads?.documentID == nil {
                Text(loc[.native_editor_media_upload_offline]).font(.footnote)
                    .foregroundStyle(theme.colors.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nativeMedia.status")
    }

    /// A same-origin attachment opens through the attachment loader (its own
    /// origin, cache and preview rules); any other http(s) URL opens in the
    /// browser only on a tap, never fetched by the app.
    @ViewBuilder private func open(_ url: String) -> some View {
        if attachments != nil, let display = parseAttachmentLink("[file](\(url))", serverOrigin: serverOrigin) {
            AttachmentCardView(display: display, isOffline: isOffline)
        } else if let target = URL(string: url), ["http", "https"].contains(target.scheme?.lowercased() ?? "") {
            Button {
                openURL(target)
            } label: {
                Label(loc[.native_media_open], systemImage: "arrow.up.forward.app")
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
        let current = MediaBlock.number(props.last { $0.key == "previewWidth" }?.value).map(Int.init)
        return (Self.widths + [current].compactMap { $0 }).reduce(into: [Int]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        .sorted()
    }

    private func slot(_ block: BlockSnapshot) -> MediaBlock.Slot {
        MediaBlock.Slot(node: block.node, url: MediaBlock.string("url", in: block.props))
    }

    private func load() {
        guard !loaded, let block else { return }
        loaded = true
        name = MediaBlock.string("name", in: block.props)
        caption = MediaBlock.string("caption", in: block.props)
    }

    private func set(_ props: [ProjectedProp]) {
        session.input?.setMediaProps(blockID, props)
    }

    /// Name and caption, as one command when either changed.
    private func commitText() {
        guard isEditable, let block else { return }
        var props: [ProjectedProp] = []
        if name != MediaBlock.string("name", in: block.props) {
            props.append(ProjectedProp(key: "name", value: .string(name)))
        }
        if caption != MediaBlock.string("caption", in: block.props) {
            props.append(ProjectedProp(key: "caption", value: .string(caption)))
        }
        guard !props.isEmpty else { return }
        set(props)
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
        if session.input?.setMediaProps(blockID, props) == true {
            link = ""
            if case .string(let value) = fileName.value { name = value }
        }
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
