import Foundation

@MainActor
@Observable
final class EditorViewModel {
    enum Mode: Equatable {
        case reading
        case blocks
        case markdown
    }

    enum SaveState: Equatable {
        case idle
        case dirty
        case saving
        case saved
        case failed(String)
    }

    /// A consume-once request to place the caret; the token makes repeated
    /// requests for the same position distinct.
    struct CursorRequest: Equatable {
        let blockID: UUID
        let offset: Int
        let token: UUID

        init(blockID: UUID, offset: Int) {
            self.blockID = blockID
            self.offset = offset
            self.token = UUID()
        }
    }

    var title: String
    var blocks: [EditorBlock] = []
    var rawMarkdown: String = ""
    var subpages: [Document] = []
    var updatedAt: Date? = nil
    var mode: Mode = .reading
    var isLoading = false
    var errorMessage: String?
    var focusedBlockID: UUID?
    var cursorRequest: CursorRequest?
    var selection: NSRange?
    var slashQueryText: String?
    /// Set when the loaded markdown wouldn't survive block editing losslessly;
    /// editing then defaults to the markdown source view.
    var openInMarkdownMode = false

    let client: DocsAPIClient
    let documentID: UUID
    let saveCoordinator: DocumentSaveCoordinator
    let autosaveInterval: Duration

    private(set) var isDirty = false
    private var savedMarkdown = ""
    private var savedTitle = ""
    private var autosaveTask: Task<Void, Never>?

    init(
        client: DocsAPIClient,
        documentID: UUID,
        title: String,
        saveCoordinator: DocumentSaveCoordinator,
        autosaveInterval: Duration = .seconds(10)
    ) {
        self.client = client
        self.documentID = documentID
        self.title = title
        self.saveCoordinator = saveCoordinator
        self.autosaveInterval = autosaveInterval
        self.savedTitle = title
    }

    var isEditing: Bool { mode != .reading }

    var saveState: SaveState {
        if isDirty { return .dirty }
        switch saveCoordinator.state(for: documentID) {
        case .idle: return .idle
        case .saving: return .saving
        case .saved: return .saved
        case .failed(let message): return .failed(message)
        }
    }

    // MARK: - Loading

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let formatted = try await client.formattedContent(documentID: documentID)
            if let fetchedTitle = formatted.title {
                title = fetchedTitle
            }
            var content = formatted.content ?? ""
            var contentTitle: String? = nil
            // Content still on its way to the server (or stranded from an
            // earlier session) is newer than what the server returned.
            if let pending = saveCoordinator.pendingSave(documentID: documentID) {
                content = pending.markdown
                contentTitle = pending.title
            } else if let draft = saveCoordinator.storedDraft(documentID: documentID),
                      formatted.updatedAt <= draft.updatedAt {
                content = draft.markdown
                contentTitle = draft.title
            }
            if let contentTitle {
                title = contentTitle
            }
            savedTitle = title
            rawMarkdown = content
            blocks = parseEditorBlocks(content)
            openInMarkdownMode = !content.isEmpty && !markdownSurvivesRoundTrip(content)
            // The dirty baseline uses the same representation currentMarkdown()
            // produces, so an unchanged document never triggers a save.
            savedMarkdown = openInMarkdownMode ? content : serializeMarkdown(blocks)
            updatedAt = formatted.updatedAt
            await loadChildren()
        } catch {
            errorMessage = "Couldn't load this document. Pull to refresh to try again."
        }
        isLoading = false
    }

    func loadChildren() async {
        subpages = (try? await client.listChildren(documentID: documentID))?.results ?? []
    }

    func addSubpage() async -> Document? {
        try? await client.createChild(documentID: documentID, title: "Untitled subpage")
    }

    // MARK: - Editing session

    func startEditing(focusing blockID: UUID? = nil) {
        errorMessage = nil
        if blocks.isEmpty {
            let seed = EditorBlock(kind: .paragraph)
            blocks = [seed]
            mode = openInMarkdownMode ? .markdown : .blocks
            if mode == .blocks {
                focusBlock(seed.id, cursorAt: 0)
            }
            return
        }
        mode = openInMarkdownMode ? .markdown : .blocks
        if mode == .blocks, let blockID, let index = blockIndex(blockID) {
            focusBlock(blockID, cursorAt: (blocks[index].text as NSString).length)
        }
    }

    func finishEditing() {
        flushPendingChanges()
        if mode == .markdown {
            blocks = parseEditorBlocks(rawMarkdown)
        }
        mode = .reading
        focusedBlockID = nil
        cursorRequest = nil
        selection = nil
        slashQueryText = nil
        errorMessage = nil
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        switch (mode, newMode) {
        case (.blocks, .markdown):
            rawMarkdown = serializeMarkdown(blocks)
        case (.markdown, .blocks):
            blocks = parseEditorBlocks(rawMarkdown)
            if blocks.isEmpty {
                blocks = [EditorBlock(kind: .paragraph)]
            }
        default:
            break
        }
        focusedBlockID = nil
        cursorRequest = nil
        selection = nil
        slashQueryText = nil
        mode = newMode
    }

    /// The markdown representation of whatever surface currently owns the content.
    func currentMarkdown() -> String {
        mode == .markdown ? rawMarkdown : serializeMarkdown(blocks)
    }

    // MARK: - Block mutations

    func updateText(blockID: UUID, text: String) {
        guard let index = blockIndex(blockID) else { return }
        guard blocks[index].text != text else { return }
        blocks[index].text = text
        markDirty()
    }

    func splitBlock(blockID: UUID, at offset: Int) {
        guard let index = blockIndex(blockID) else { return }
        let block = blocks[index]

        // Enter on an empty list item escapes back to a paragraph.
        if block.text.isEmpty, isListKind(block.kind) {
            blocks[index].kind = .paragraph
            focusBlock(block.id, cursorAt: 0)
            markDirty()
            return
        }

        let text = block.text as NSString
        let splitOffset = min(max(0, offset), text.length)
        blocks[index].text = text.substring(to: splitOffset)
        let newBlock = EditorBlock(
            kind: continuationKind(after: block.kind),
            text: text.substring(from: splitOffset)
        )
        blocks.insert(newBlock, at: index + 1)
        focusBlock(newBlock.id, cursorAt: 0)
        markDirty()
    }

    func mergeBlockWithPrevious(blockID: UUID) {
        guard let index = blockIndex(blockID) else { return }
        let block = blocks[index]

        // A styled block first converts back to a paragraph.
        if block.kind != .paragraph {
            blocks[index].kind = .paragraph
            focusBlock(block.id, cursorAt: 0)
            markDirty()
            return
        }

        guard index > 0 else { return }
        let previous = blocks[index - 1]
        switch previous.kind {
        case .divider:
            blocks.remove(at: index - 1)
            focusBlock(block.id, cursorAt: 0)
            markDirty()
        case .codeBlock, .unknown:
            let caret = (previous.text as NSString).length
            if !block.text.isEmpty {
                blocks[index - 1].text += previous.text.isEmpty ? block.text : "\n" + block.text
            }
            blocks.remove(at: index)
            focusBlock(previous.id, cursorAt: caret)
            markDirty()
        default:
            let caret = (previous.text as NSString).length
            blocks[index - 1].text += block.text
            blocks.remove(at: index)
            focusBlock(previous.id, cursorAt: caret)
            markDirty()
        }
    }

    func toggleChecklist(blockID: UUID) {
        guard let index = blockIndex(blockID),
              case .checklistItem(let checked) = blocks[index].kind else { return }
        blocks[index].kind = .checklistItem(checked: !checked)
        markDirty()
    }

    func convertBlock(blockID: UUID, to kind: BlockKind) {
        guard let index = blockIndex(blockID) else { return }
        if blocks[index].kind == kind {
            blocks[index].kind = .paragraph
        } else {
            blocks[index].kind = kind
            if kind == .divider {
                blocks[index].text = ""
            }
        }
        markDirty()
    }

    func insertBlock(after blockID: UUID?, kind: BlockKind) {
        let newBlock = EditorBlock(kind: kind)
        let insertionIndex: Int
        if let blockID, let index = blockIndex(blockID) {
            insertionIndex = index + 1
        } else {
            insertionIndex = blocks.count
        }
        blocks.insert(newBlock, at: insertionIndex)
        if kind != .divider {
            focusBlock(newBlock.id, cursorAt: 0)
        }
        markDirty()
    }

    /// Tap on the empty canvas below the last block: reuse a trailing empty
    /// paragraph if there is one, otherwise append a new one.
    func appendParagraphAtEnd() {
        if let last = blocks.last, last.kind == .paragraph, last.text.isEmpty {
            focusBlock(last.id, cursorAt: 0)
            return
        }
        insertBlock(after: blocks.last?.id, kind: .paragraph)
    }

    func updateTitle(_ text: String) {
        guard title != text else { return }
        title = text
        markDirty()
    }

    func updateRawMarkdown(_ text: String) {
        guard rawMarkdown != text else { return }
        rawMarkdown = text
        markDirty()
    }

    // MARK: - Saving

    /// Cancels the debounce and hands the current content to the save
    /// coordinator, which persists a draft immediately and saves in the
    /// background, outliving this screen.
    func flushPendingChanges() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard isDirty else { return }
        isDirty = false
        let markdown = currentMarkdown()
        if markdown == savedMarkdown, title == savedTitle {
            return
        }
        savedMarkdown = markdown
        savedTitle = title
        saveCoordinator.enqueue(documentID: documentID, title: title, markdown: markdown)
    }

    /// Manual save: flushes dirty edits, or retries the last content after a failure.
    func saveNow() {
        if isDirty {
            flushPendingChanges()
            return
        }
        if case .failed = saveCoordinator.state(for: documentID) {
            saveCoordinator.enqueue(documentID: documentID, title: savedTitle, markdown: savedMarkdown)
        }
    }

    private func markDirty() {
        isDirty = true
        let interval = autosaveInterval
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.flushPendingChanges()
        }
    }

    // MARK: - Helpers

    private func blockIndex(_ blockID: UUID) -> Int? {
        blocks.firstIndex { $0.id == blockID }
    }

    private func focusBlock(_ blockID: UUID, cursorAt offset: Int) {
        focusedBlockID = blockID
        cursorRequest = CursorRequest(blockID: blockID, offset: offset)
    }

    private func isListKind(_ kind: BlockKind) -> Bool {
        switch kind {
        case .bulletItem, .numberedItem, .checklistItem:
            return true
        default:
            return false
        }
    }

    private func continuationKind(after kind: BlockKind) -> BlockKind {
        switch kind {
        case .bulletItem:
            return .bulletItem
        case .numberedItem:
            return .numberedItem
        case .checklistItem:
            return .checklistItem(checked: false)
        default:
            return .paragraph
        }
    }
}
