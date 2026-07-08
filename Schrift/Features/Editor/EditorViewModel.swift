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

    /// A consume-once request to place the caret or selection; the token makes
    /// repeated requests for the same position distinct.
    struct CursorRequest: Equatable {
        let blockID: UUID
        let offset: Int
        let length: Int
        let token: UUID

        init(blockID: UUID, offset: Int, length: Int = 0) {
            self.blockID = blockID
            self.offset = offset
            self.length = length
            self.token = UUID()
        }
    }

    enum DisplaySource: Equatable {
        case none, pendingSave, draft, clean
    }

    var title: String
    var blocks: [EditorBlock] = []
    var rawMarkdown: String = ""
    /// nil = no fetched *or cached* knowledge (the view must not claim "no
    /// subpages"); [] = a real result — fetched this session or restored from
    /// the children cache — with none existing.
    var subpages: [Document]? = nil
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
    var lastSyncedAt: Date? = nil
    var hasLocalCopy = false
    var updateAvailable = false
    /// Drives the system photo picker. Set by the slash-menu photo item and the
    /// formatting-bar button; cleared by SwiftUI when the picker dismisses.
    var isPhotoPickerPresented = false
    /// True while a picked photo is being prepared, uploaded and confirmed. No
    /// placeholder block exists during this window — the `.image` block is only
    /// inserted on success.
    var isUploadingPhoto = false

    let client: DocsAPIClient
    let documentID: UUID
    let saveCoordinator: DocumentSaveCoordinator
    let contentCache: DocumentContentCacheStore
    let childrenCache: DocumentChildrenCacheStore
    let autosaveInterval: Duration
    /// Delay between media-check readiness polls. Tests pass `.zero`.
    let mediaCheckRetryInterval: Duration

    private(set) var isDirty = false
    /// Editing is only allowed once content has loaded — otherwise autosave
    /// would overwrite the whole server document with an empty draft.
    private(set) var hasLoadedContent = false
    private(set) var displaySource: DisplaySource = .none
    private var savedMarkdown = ""
    private var savedTitle = ""
    private var autosaveTask: Task<Void, Never>?
    private var dirtySince: Date?
    private var pendingFreshContent: (markdown: String, syncedAt: Date)?
    /// Monotonic guard: a completing fetch applies its outcome only if no
    /// newer load()/refresh() superseded it (latest-wins; .task refires on
    /// pop-back and .refreshable re-enters).
    private var revalidationGeneration = 0
    /// Latest-wins guard for the children list: bumped by every loadChildren(),
    /// a successful addSubpage(), and the purge paths, so a stale in-flight
    /// listChildren snapshot can never overwrite (and durably cache) a newer
    /// mutation. Read-only outside the type so tests can pin the bumps whose
    /// interleaving can't be simulated (MockURLProtocol serializes requests).
    private(set) var childrenGeneration = 0
    /// The exact raw markdown the current display was installed from — the
    /// staleness comparison basis. NEVER compare fetched markdown against
    /// serializeMarkdown(blocks)/currentMarkdown(): the serializer
    /// canonicalizes (`*`→`-`, renumbering), which would give every
    /// non-byte-round-tripping document a permanent do-nothing banner.
    private var displayedSourceMarkdown = ""

    /// Continuous typing keeps restarting the trailing debounce; cap the total
    /// deferral so a long burst still persists periodically.
    private static let maxAutosaveDeferral: TimeInterval = 30

    /// How many times to poll media-check before falling back to the URL derived
    /// from the upload key. The default deployment's scanner is the dummy
    /// backend, so readiness is near-immediate.
    private static let mediaCheckMaxAttempts = 5

    /// Friendly copy for every failure in the photo-insert pipeline.
    private static let photoErrorMessage = "Couldn't add the photo. Please try again."

    init(
        client: DocsAPIClient,
        documentID: UUID,
        title: String,
        saveCoordinator: DocumentSaveCoordinator,
        contentCache: DocumentContentCacheStore = DocumentContentCacheStore(),
        childrenCache: DocumentChildrenCacheStore = DocumentChildrenCacheStore(),
        autosaveInterval: Duration = .seconds(10),
        mediaCheckRetryInterval: Duration = .seconds(1)
    ) {
        self.client = client
        self.documentID = documentID
        self.title = title
        self.saveCoordinator = saveCoordinator
        self.contentCache = contentCache
        self.childrenCache = childrenCache
        self.autosaveInterval = autosaveInterval
        self.mediaCheckRetryInterval = mediaCheckRetryInterval
        self.savedTitle = title
    }

    var isEditing: Bool { mode != .reading }

    /// Caption rule 1: unsaved local content wins over "Synced X ago".
    var hasUnsavedLocalContent: Bool {
        isDirty
            || saveCoordinator.pendingSave(documentID: documentID) != nil
            || (displaySource == .draft && saveCoordinator.storedDraft(documentID: documentID) != nil)
    }

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
        errorMessage = nil
        // The local phase runs once per installed document: load() re-fires
        // on pop-back (.task) — reinstalling would clobber a dirty editing
        // session with the cached copy. After the first install, load() is
        // revalidate-only.
        if !hasLoadedContent {
            updateAvailable = false
            pendingFreshContent = nil
            // Sub pages restore alongside the content so the Subpages section
            // renders instantly (and offline); loadChildren revalidates after
            // each successful content fetch.
            if let cachedChildren = childrenCache.children(for: documentID) {
                subpages = cachedChildren
            }
            restoreLocalContent()
            if displaySource == .none {
                isLoading = true
            }
        }
        revalidationGeneration += 1
        await revalidate(generation: revalidationGeneration)
        isLoading = false
    }

    /// Local phase: synchronous, no network, no spinner. Chooses the display
    /// source by precedence — in-flight save, stored draft, cached copy.
    private func restoreLocalContent() {
        if let pending = saveCoordinator.pendingSave(documentID: documentID) {
            install(markdown: pending.markdown, title: pending.title, syncedAt: nil)
            displaySource = .pendingSave
        } else if let draft = saveCoordinator.storedDraft(documentID: documentID) {
            // New: shown before any fetch (fixes drafts being unreachable
            // offline). The server-wins staleness rule runs at revalidation.
            install(markdown: draft.markdown, title: draft.title, syncedAt: nil)
            displaySource = .draft
        } else if let cached = contentCache.content(for: documentID) {
            install(markdown: cached.markdown, title: cached.title, syncedAt: cached.syncedAt)
            displaySource = .clean
        } else {
            displaySource = .none
        }
        hasLocalCopy = displaySource != .none
    }

    /// Revalidation: the awaited structured tail of load() — no unstructured
    /// Task. Classification of the outcome happens when the fetch completes.
    /// `generation` guards against a superseded fetch (an earlier load() or
    /// refresh()) applying its outcome after a newer one has already run.
    private func revalidate(generation: Int) async {
        do {
            let formatted = try await client.formattedContent(documentID: documentID)
            guard generation == revalidationGeneration, !Task.isCancelled else { return }
            apply(formatted: formatted)
            await loadChildren()
        } catch let error as DocsAPIError where error == .notFound || error == .forbidden {
            guard generation == revalidationGeneration else { return }
            becomeUnavailable()
        } catch {
            guard generation == revalidationGeneration else { return }
            // Transient (.network, .server, .rateLimited, .sessionExpired —
            // cookie expiry must not purge the cache): keep the local copy.
            // For .sessionExpired specifically, the shared client's
            // onSessionExpired hook has already raised the app-level re-login
            // sheet; the editor recovers on its next refresh or save.
            if displaySource == .none {
                errorMessage = "Couldn't load this document. Pull to refresh to try again."
            }
        }
    }

    /// Explicit pull-to-refresh. Unlike the passive on-open revalidation it
    /// awaits the fetch (the refresh spinner reflects real work), applies a
    /// changed server copy DIRECTLY when clean (the user asked — no banner),
    /// and surfaces failures instead of swallowing them.
    func refresh() async {
        guard hasLoadedContent else {
            await load()  // error-state retry: full initial flow, as today
            return
        }
        errorMessage = nil
        revalidationGeneration += 1
        let generation = revalidationGeneration
        do {
            let formatted = try await client.formattedContent(documentID: documentID)
            guard generation == revalidationGeneration, !Task.isCancelled else { return }
            apply(formatted: formatted, userInitiated: true)
            await loadChildren()
        } catch let error as DocsAPIError where error == .notFound || error == .forbidden {
            guard generation == revalidationGeneration else { return }
            becomeUnavailable()
        } catch {
            guard generation == revalidationGeneration else { return }
            errorMessage = "Couldn't refresh. Please try again."
        }
    }

    /// Definitive 404/403: the document is gone or access was revoked. Purge
    /// the durable copy (privacy), disable editing, show the terminal state.
    private func becomeUnavailable() {
        contentCache.remove(documentID: documentID)
        childrenCache.remove(parentID: documentID)
        childrenCache.removeDocument(documentID)
        // Discard any in-flight children snapshot — landing after the purge,
        // it would re-cache the list for a revoked document.
        childrenGeneration += 1
        subpages = nil
        hasLocalCopy = false
        lastSyncedAt = nil
        updateAvailable = false
        pendingFreshContent = nil
        blocks = []
        rawMarkdown = ""
        displayedSourceMarkdown = ""
        displaySource = .none
        hasLoadedContent = false  // startEditing guards on this
        errorMessage = "This document is no longer available."
    }

    private func apply(formatted: FormattedDocumentContent, userInitiated: Bool = false) {
        defer { updatedAt = formatted.updatedAt }
        // Classify against *current* state: edits may have begun while the
        // fetch was in flight.
        if saveCoordinator.pendingSave(documentID: documentID) != nil || isDirty {
            cacheServerCopy(formatted)
            return
        }
        switch displaySource {
        case .pendingSave:
            break  // in-flight content is newer than the server copy
        case .draft:
            if let draft = saveCoordinator.storedDraft(documentID: documentID),
                formatted.updatedAt <= draft.updatedAt.addingTimeInterval(pendingDraftClockTolerance)
            {
                cacheServerCopy(formatted)
            } else {
                // Server newer beyond tolerance: today the stale draft would
                // never have been shown — server wins, and the draft goes
                // (re-checked inside discardStoredDraft; the user may have
                // produced a newer one while we awaited).
                if let draft = saveCoordinator.storedDraft(documentID: documentID) {
                    saveCoordinator.discardStoredDraft(draft)
                }
                installFetched(formatted)
            }
        case .none:
            installFetched(formatted)
        case .clean:
            reconcileClean(formatted, applyDirectly: userInitiated)
        }
    }

    /// Silent cache update while local edits own the screen — next open (or
    /// the coordinator's own conflict handling) deals with freshness.
    private func cacheServerCopy(_ formatted: FormattedDocumentContent) {
        contentCache.save(
            CachedDocumentContent(
                documentID: documentID,
                title: formatted.title,
                markdown: formatted.content ?? "",
                syncedAt: Date()
            ))
    }

    /// Clean content on screen: never swap it on a passive open. Titles are
    /// non-destructive and apply silently in BOTH branches (savedTitle follows
    /// so flushPendingChanges never enqueues a spurious save); only body
    /// differences drive the banner — unless `applyDirectly` (explicit
    /// refresh()), which installs the fetched body immediately instead of
    /// stashing it behind the "Updated" banner.
    private func reconcileClean(_ formatted: FormattedDocumentContent, applyDirectly: Bool = false) {
        let fetched = formatted.content ?? ""
        let now = Date()
        if let fetchedTitle = formatted.title, fetchedTitle != title {
            title = fetchedTitle
            savedTitle = fetchedTitle
        }
        contentCache.save(
            CachedDocumentContent(
                documentID: documentID,
                title: title,
                markdown: fetched,
                syncedAt: now
            ))
        if serverChanged(fetched: fetched) {
            if applyDirectly {
                install(markdown: fetched, title: nil, syncedAt: now)
                updateAvailable = false
                pendingFreshContent = nil
            } else {
                pendingFreshContent = (markdown: fetched, syncedAt: now)
                updateAvailable = true
            }
        } else {
            // Raw may differ only cosmetically — converge the comparison
            // basis on the fetched raw so future comparisons settle.
            displayedSourceMarkdown = fetched
            lastSyncedAt = now
            if applyDirectly {
                updateAvailable = false
                pendingFreshContent = nil
            }
        }
    }

    private func serverChanged(fetched: String) -> Bool {
        guard fetched != displayedSourceMarkdown else { return false }
        return serializeMarkdown(parseEditorBlocks(fetched))
            != serializeMarkdown(parseEditorBlocks(displayedSourceMarkdown))
    }

    /// The "Updated" banner tap: swaps in the stashed fresh body. Guarded so a
    /// stray tap can never replace blocks mid-edit or clobber dirty content.
    func applyPendingUpdate() {
        guard !isEditing, !isDirty, let pending = pendingFreshContent else { return }
        install(markdown: pending.markdown, title: nil, syncedAt: pending.syncedAt)
        displaySource = .clean
        updateAvailable = false
        pendingFreshContent = nil
    }

    /// A successful local delete must purge every local copy — otherwise the
    /// document stays reachable from retained Search/Shared results and
    /// renders its full cached content indefinitely (transient revalidation
    /// failures are swallowed by design).
    func handleDidDelete() {
        contentCache.remove(documentID: documentID)
        childrenCache.remove(parentID: documentID)
        childrenCache.removeDocument(documentID)
        // Discard any in-flight children snapshot — landing after the purge,
        // it would re-cache the list for a deleted document.
        childrenGeneration += 1
        saveCoordinator.discardPendingWork(documentID: documentID)
    }

    /// Installs the fetched server copy and records it in the content cache.
    private func installFetched(_ formatted: FormattedDocumentContent) {
        let now = Date()
        install(markdown: formatted.content ?? "", title: formatted.title, syncedAt: now)
        displaySource = .clean
        hasLocalCopy = true
        contentCache.save(
            CachedDocumentContent(
                documentID: documentID,
                title: title,
                markdown: formatted.content ?? "",
                syncedAt: now
            ))
    }

    /// Installs content as the on-screen document. Every path that puts
    /// content on screen routes through here so the round-trip safety check
    /// and the dirty baseline are never bypassed — skipping them risks a
    /// destructive full-overwrite save of non-round-trippable content.
    private func install(markdown: String, title contentTitle: String?, syncedAt: Date?) {
        if let contentTitle {
            title = contentTitle
        }
        savedTitle = title
        rawMarkdown = markdown
        blocks = parseEditorBlocks(markdown)
        openInMarkdownMode = !markdown.isEmpty && !markdownSurvivesRoundTrip(markdown)
        // The dirty baseline uses the same representation currentMarkdown()
        // produces, so an unchanged document never triggers a save.
        savedMarkdown = openInMarkdownMode ? markdown : serializeMarkdown(blocks)
        displayedSourceMarkdown = markdown
        hasLoadedContent = true
        if let syncedAt {
            lastSyncedAt = syncedAt
        }
    }

    func loadChildren() async {
        childrenGeneration += 1
        let generation = childrenGeneration
        guard let results = try? await client.listChildren(documentID: documentID) else { return }
        // Superseded by a newer fetch or a createChild while in flight: a
        // pre-create snapshot must not overwrite (and durably cache) a list
        // missing the just-added child.
        guard generation == childrenGeneration else { return }
        subpages = results.results
        childrenCache.save(results.results, for: documentID)
    }

    func addSubpage() async -> Document? {
        guard let child = try? await client.createChild(documentID: documentID, title: "Untitled subpage") else {
            return nil
        }
        // Any in-flight children fetch predates this child — invalidate it.
        childrenGeneration += 1
        // Reflect the new child immediately (and durably) so popping back —
        // possibly offline — shows it without waiting on a refetch. Only when
        // the current list is actually known (fetched or cached): appending to
        // a nil (unknown) list would persist a fabricated one-element "complete"
        // result that hides the document's real children.
        if var updated = subpages {
            updated.append(child)
            subpages = updated
            childrenCache.save(updated, for: documentID)
        }
        return child
    }

    // MARK: - Editing session

    func startEditing(focusing blockID: UUID? = nil) {
        guard hasLoadedContent else { return }
        errorMessage = nil
        updateAvailable = false
        pendingFreshContent = nil
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
        // Keep both representations in sync so the next editing session
        // (whichever mode it opens in) never shows or saves stale content.
        if mode == .markdown {
            blocks = parseEditorBlocks(rawMarkdown)
        } else {
            rawMarkdown = serializeMarkdown(blocks)
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
    /// Only **blocks** mode makes `blocks` authoritative. In markdown mode the user
    /// is editing the source directly, and in reading mode `rawMarkdown` is kept in
    /// sync by `install`/`finishEditing`/`setMode` while `blocks` may be a lossy
    /// parse of it — so a full-overwrite save must carry the source, not the
    /// serialization. Do **not** key this off `openInMarkdownMode`: that flag is
    /// computed once in `install` and goes stale the moment a session authors
    /// content the block model can't represent.
    func currentMarkdown() -> String {
        mode == .blocks ? serializeMarkdown(blocks) : rawMarkdown
    }

    // MARK: - Block mutations

    func updateText(blockID: UUID, text: String) {
        guard let index = blockIndex(blockID) else { return }
        guard blocks[index].text != text else { return }

        // Markdown typing shortcuts convert a paragraph as soon as its prefix lands.
        if blocks[index].kind == .paragraph, let match = detectMarkdownShortcut(text: text) {
            blocks[index].kind = match.kind
            blocks[index].text = match.remainderText
            slashQueryText = nil
            // The caret stays where the user was typing, shifted back by the
            // consumed prefix — not at the end of any pre-existing text.
            let prefixLength = (text as NSString).length - (match.remainderText as NSString).length
            let caretBefore = selection?.location ?? (text as NSString).length
            let caret = min(max(0, caretBefore - prefixLength), (match.remainderText as NSString).length)
            focusBlock(blockID, cursorAt: caret)
            markDirty()
            return
        }

        blocks[index].text = text
        slashQueryText = focusedBlockID == blockID ? slashQuery(text: text, kind: blocks[index].kind) : nil
        markDirty()
    }

    func splitBlock(blockID: UUID, at offset: Int) {
        guard let index = blockIndex(blockID) else { return }
        let block = blocks[index]
        slashQueryText = nil

        // "```swift" or "---" followed by Return converts instead of splitting.
        if block.kind == .paragraph, let match = detectEnterShortcut(text: block.text) {
            blocks[index].kind = match.kind
            blocks[index].text = match.remainderText
            if match.kind == .divider {
                let newBlock = EditorBlock(kind: .paragraph)
                blocks.insert(newBlock, at: index + 1)
                focusBlock(newBlock.id, cursorAt: 0)
            } else {
                focusBlock(block.id, cursorAt: 0)
            }
            markDirty()
            return
        }

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
        case .divider, .image:
            // Leaf blocks (divider, image) have no text to merge into; backspace
            // at the start of the following block removes the leaf as a unit.
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
            case .checklistItem(let checked) = blocks[index].kind
        else { return }
        blocks[index].kind = .checklistItem(checked: !checked)
        markDirty()
    }

    func convertBlock(blockID: UUID, to kind: BlockKind) {
        guard let index = blockIndex(blockID) else { return }
        // An image's data lives in its kind's associated values; converting would
        // silently destroy the image, so images are never converted.
        if case .image = blocks[index].kind { return }
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

    // MARK: - Formatting bar actions

    /// Wraps (or unwraps) the current selection in an inline markdown marker.
    /// With no selection, inserts a marker pair and places the caret between.
    func applyInlineMarker(_ marker: String) {
        if mode == .markdown {
            let range = selection ?? NSRange(location: (rawMarkdown as NSString).length, length: 0)
            let result = wrapInlineMarker(text: rawMarkdown, range: range, marker: marker)
            rawMarkdown = result.text
            selection = result.selection
            markDirty()
            return
        }
        guard let focusedBlockID, let index = blockIndex(focusedBlockID) else { return }
        switch blocks[index].kind {
        case .codeBlock, .unknown, .divider, .image:
            return
        default:
            break
        }
        let range = selection ?? NSRange(location: (blocks[index].text as NSString).length, length: 0)
        let result = wrapInlineMarker(text: blocks[index].text, range: range, marker: marker)
        blocks[index].text = result.text
        cursorRequest = CursorRequest(
            blockID: focusedBlockID, offset: result.selection.location, length: result.selection.length)
        selection = result.selection
        markDirty()
    }

    /// Converts the focused block's type (blocks mode).
    func convertFocusedBlock(to kind: BlockKind) {
        guard let focusedBlockID else { return }
        convertBlock(blockID: focusedBlockID, to: kind)
    }

    /// Inserts a divider below the focused block (or at the end), keeping an
    /// editable paragraph after it.
    func insertDividerBelowFocused() {
        let anchorID = focusedBlockID ?? blocks.last?.id
        let insertionIndex: Int
        if let anchorID, let index = blockIndex(anchorID) {
            insertionIndex = index + 1
        } else {
            insertionIndex = blocks.count
        }
        let divider = EditorBlock(kind: .divider)
        blocks.insert(divider, at: insertionIndex)
        if insertionIndex == blocks.count - 1 {
            let paragraph = EditorBlock(kind: .paragraph)
            blocks.insert(paragraph, at: insertionIndex + 1)
            focusBlock(paragraph.id, cursorAt: 0)
        }
        markDirty()
    }

    /// Inserts raw text at the caret in markdown-source mode.
    func insertAtCursor(_ token: String) {
        let source = rawMarkdown as NSString
        var range = selection ?? NSRange(location: source.length, length: 0)
        range.location = min(max(0, range.location), source.length)
        range.length = min(max(0, range.length), source.length - range.location)
        rawMarkdown = source.replacingCharacters(in: range, with: token)
        selection = NSRange(location: range.location + (token as NSString).length, length: 0)
        markDirty()
    }

    /// Applies a block type chosen from the slash menu to the focused block,
    /// consuming the "/query" text.
    func applySlashSelection(_ item: SlashMenuItem) {
        guard let focusedBlockID, let index = blockIndex(focusedBlockID) else { return }
        // Photo is the one item that can decline: while an upload is in flight the
        // picker won't open. Bail out *before* consuming the "/photo" text, or the
        // selection would silently eat what the user typed and do nothing.
        if case .insertPhoto = item.action, !canInsertPhoto { return }
        blocks[index].text = ""
        slashQueryText = nil
        switch item.action {
        case .convert(.divider):
            blocks[index].kind = .divider
            let newBlock = EditorBlock(kind: .paragraph)
            blocks.insert(newBlock, at: index + 1)
            focusBlock(newBlock.id, cursorAt: 0)
        case .convert(let kind):
            blocks[index].kind = kind
            focusBlock(focusedBlockID, cursorAt: 0)
        case .insertPhoto:
            // The block stays an empty paragraph; `insertImageBlock` replaces it
            // in place once the upload succeeds (and leaves it alone if it
            // doesn't, so a failed pick never strands a placeholder).
            focusBlock(focusedBlockID, cursorAt: 0)
            requestPhotoInsertion()
        }
        markDirty()
    }

    // MARK: - Photo insertion

    /// Editing may only begin once content has loaded, and one upload at a time.
    /// Both photo entry points share this gate.
    var canInsertPhoto: Bool { hasLoadedContent && !isUploadingPhoto }

    /// Entry point for both the formatting-bar button and the slash-menu item.
    func requestPhotoInsertion() {
        guard canInsertPhoto else { return }
        isPhotoPickerPresented = true
    }

    /// Runs the picked photo through prepare → upload → readiness poll and
    /// inserts the resulting `.image` block. A cancelled pick (`nil` data) is a
    /// silent no-op; any failure sets friendly copy and inserts nothing, so a
    /// broken upload can never leave a placeholder in the document.
    func insertPhoto(loadingData: @Sendable () async throws -> Data?) async {
        guard canInsertPhoto else { return }
        isUploadingPhoto = true
        defer { isUploadingPhoto = false }
        do {
            guard let originalData = try await loadingData() else { return }
            // Decoding a 48 MP HEIC and re-encoding it must not block the main
            // thread (the uploading spinner would freeze). `preparedJPEGData` is a
            // pure function over Sendable values, so it can run anywhere.
            let prepared = await Task.detached(priority: .userInitiated) {
                preparedJPEGData(from: originalData)
            }.value
            guard let jpegData = prepared else {
                errorMessage = Self.photoErrorMessage
                return
            }
            let mediaCheckPath = try await client.uploadAttachment(
                documentID: documentID, fileName: "photo.jpg", contentType: "image/jpeg", data: jpegData)
            guard let urlString = await readyMediaURLString(fromMediaCheckPath: mediaCheckPath) else {
                errorMessage = Self.photoErrorMessage
                return
            }
            insertImageBlock(url: urlString)
        } catch {
            errorMessage = Self.photoErrorMessage
        }
    }

    /// Polls media-check until the attachment is ready and returns the absolute
    /// media URL to embed (matching what the web client persists). Falls back to
    /// the URL derived from the upload key if readiness can't be confirmed in
    /// time — the upload already succeeded, so the URL must never be lost.
    private func readyMediaURLString(fromMediaCheckPath path: String) async -> String? {
        for attempt in 0..<Self.mediaCheckMaxAttempts {
            if attempt > 0 { try? await Task.sleep(for: mediaCheckRetryInterval) }
            if let response = try? await client.checkMedia(path: path),
                response.status == MediaCheckResponse.readyStatus, let file = response.file,
                let absolute = await client.absoluteServerURL(for: file)
            {
                return absolute.absoluteString
            }
        }
        guard let key = attachmentKey(fromMediaCheckPath: path),
            let absolute = await client.absoluteServerURL(for: "/media/" + key)
        else { return nil }
        return absolute.absoluteString
    }

    /// Mirrors the divider slash behavior: replace a focused empty paragraph in
    /// place, otherwise insert below the focused block, and always leave an
    /// editable paragraph after the image (an image is a non-editable leaf).
    ///
    /// The upload can outlive the editing session: neither Done nor a navigation
    /// pop cancels the picker's `Task`. **Every** path therefore persists
    /// immediately rather than through `markDirty`'s debounce, whose `autosaveTask`
    /// is owned by this view model — a pop releases the last strong reference, so
    /// the debounced `self?.flushPendingChanges()` no-ops and the finished upload
    /// is silently lost. A pop also leaves `mode` untouched (only `finishEditing`
    /// sets `.reading`), so this must not be keyed off the mode. Flushing enqueues
    /// on the app-scoped save coordinator, which owns its `Task`s precisely so
    /// navigating away can never cancel a save.
    private func insertImageBlock(url: String) {
        defer { flushPendingChanges() }

        if mode == .markdown {
            // The image markdown must land on a line of its own: `parseImageLine`
            // is column-zero anchored and requires the line to *end* in `)`, so
            // `Hello![](url)` would round-trip as literal text, not an image. The
            // surrounding blank lines also keep it out of an adjacent paragraph.
            insertAtCursor("\n\n![](\(url))\n\n")  // marks dirty
            return
        }

        // The session already ended. Append to the authoritative source — `blocks`
        // may be a lossy parse of it — rather than to a serialization that would
        // rewrite what the user actually wrote.
        if mode == .reading {
            rawMarkdown = markdownAppendingImage(to: currentMarkdown(), url: url)
            blocks = parseEditorBlocks(rawMarkdown)
            markDirty()
            return
        }

        let image = EditorBlock(kind: .image(alt: "", url: url))
        let trailing = EditorBlock(kind: .paragraph)
        if let focusedBlockID, let index = blockIndex(focusedBlockID) {
            if blocks[index].kind == .paragraph, blocks[index].text.isEmpty {
                blocks[index] = image
                blocks.insert(trailing, at: index + 1)
            } else {
                blocks.insert(image, at: index + 1)
                blocks.insert(trailing, at: index + 2)
            }
        } else {
            blocks.append(image)
            blocks.append(trailing)
        }
        focusBlock(trailing.id, cursorAt: 0)
        markDirty()
    }

    /// Appends a standalone image line, blank-line separated so it parses as an
    /// `.image` block rather than being absorbed into the trailing paragraph.
    private func markdownAppendingImage(to source: String, url: String) -> String {
        let imageLine = "![](\(url))\n"
        guard !source.isEmpty else { return imageLine }
        return source + (source.hasSuffix("\n") ? "" : "\n") + "\n" + imageLine
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
        dirtySince = nil
        guard isDirty else { return }
        isDirty = false
        let markdown = currentMarkdown()
        if markdown == savedMarkdown, title == savedTitle {
            return
        }
        savedMarkdown = markdown
        savedTitle = title
        displayedSourceMarkdown = markdown
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
        if updateAvailable {
            updateAvailable = false
            pendingFreshContent = nil
        }
        isDirty = true
        let now = Date()
        if dirtySince == nil {
            dirtySince = now
        }
        if let dirtySince, now.timeIntervalSince(dirtySince) >= Self.maxAutosaveDeferral {
            flushPendingChanges()
            return
        }
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
        // Programmatic caret moves don't echo back through the text view's
        // delegate, so keep the tracked selection in sync here.
        selection = NSRange(location: offset, length: 0)
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
