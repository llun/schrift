import Darwin
import Foundation
import Synchronization
import UIKit
import UniformTypeIdentifiers

/// Classification, pasteboard precedence, and synchronous staging for
/// dragged/pasted images, videos, audio, PDFs, and files (PR13b2).
enum NativeMediaDropPaste {
    static let maxItemsPerOperation = 10

    enum PayloadKind: Equatable, Sendable {
        case media(node: String, isImage: Bool)
        case file
        case ignore

        var node: String? {
            switch self {
            case .media(let node, _): node
            case .file: "file"
            case .ignore: nil
            }
        }

        var isPhoto: Bool {
            if case .media(_, let isImage) = self { return isImage }
            return false
        }
    }

    enum PasteboardIntent {
        case textOrPayload
        case media([(provider: NSItemProvider, kind: PayloadKind)])
        case empty
    }

    /// UTType identifiers queried on `UIPasteboard.contains(pasteboardTypes:)`
    /// inside `canPerformAction` without reading pasteboard item contents.
    static let pasteboardMediaIdentifiers: [String] = [
        UTType.image.identifier,
        UTType.movie.identifier,
        UTType.video.identifier,
        UTType.audio.identifier,
        UTType.pdf.identifier,
        UTType.fileURL.identifier,
        UTType.archive.identifier,
        UTType.data.identifier,
    ]

    /// True when a drop session carries at least one media or file item that
    /// `NativeMediaDropController` should claim.
    @MainActor
    static func containsMediaItems(in session: UIDropSession) -> Bool {
        mediaProviders(from: session.items.map { $0.itemProvider }).isEmpty == false
    }

    /// Extracts `(provider, kind)` pairs from drag-and-drop item providers.
    static func mediaProviders(from providers: [NSItemProvider]) -> [(provider: NSItemProvider, kind: PayloadKind)] {
        providers.compactMap { provider in
            let kind = classifyDropProvider(provider)
            return kind == .ignore ? nil : (provider, kind)
        }
    }

    /// Decides whether `pasteboard` should run existing text/Schrift-payload
    /// paste or media/file upload paste, enforcing text-before-media precedence.
    @MainActor
    static func classifyPasteboard(_ pasteboard: UIPasteboard) -> PasteboardIntent {
        if pasteboard.contains(pasteboardTypes: [
            BlockNoteSubtreePayload.pasteboardType,
            BlockNoteInlinePayload.pasteboardType,
        ]) {
            return .textOrPayload
        }

        let providers = pasteboard.itemProviders
        guard !providers.isEmpty else {
            if pasteboard.hasStrings || pasteboard.hasURLs { return .textOrPayload }
            return .empty
        }

        for provider in providers where prefersTextPaste(provider) {
            return .textOrPayload
        }

        let media: [(provider: NSItemProvider, kind: PayloadKind)] = providers.compactMap { provider in
            let kind = classifyPasteProvider(provider)
            return kind == .ignore ? nil : (provider, kind)
        }
        if !media.isEmpty { return .media(media) }

        if pasteboard.hasStrings || pasteboard.hasURLs {
            return .textOrPayload
        }
        return .empty
    }

    /// Classifies a single `NSItemProvider` for drag-and-drop.
    static func classifyDropProvider(_ provider: NSItemProvider) -> PayloadKind {
        classifyProvider(provider, treatNamedTextAsFile: true)
    }

    /// Classifies a single `NSItemProvider` for paste (after text precedence).
    static func classifyPasteProvider(_ provider: NSItemProvider) -> PayloadKind {
        classifyProvider(provider, treatNamedTextAsFile: false)
    }

    private static func prefersTextPaste(_ provider: NSItemProvider) -> Bool {
        let hasFileURL = conforms(provider, to: .fileURL)
        if hasFileURL { return false }

        if conforms(provider, to: .html)
            || conforms(provider, to: .rtf)
            || conforms(provider, to: .rtfd)
            || conforms(provider, to: .flatRTFD)
            || conforms(provider, to: .webArchive)
            || conforms(provider, to: .plainText)
        {
            return true
        }

        guard conforms(provider, to: .url) else { return false }

        let hasMediaType =
            conforms(provider, to: .image)
            || conforms(provider, to: .audiovisualContent)
            || conforms(provider, to: .pdf)
            || hasNonTextDataType(provider)
        return !hasMediaType
    }

    private static func classifyProvider(_ provider: NSItemProvider, treatNamedTextAsFile: Bool) -> PayloadKind {
        if isBareDirectory(provider) { return .ignore }
        if conforms(provider, to: .pdf) { return .media(node: "pdf", isImage: false) }
        if conforms(provider, to: .image) {
            if isVectorOnlySVG(provider) { return .file }
            return .media(node: "image", isImage: true)
        }
        if conforms(provider, to: .movie) || conforms(provider, to: .video) {
            return .media(node: "video", isImage: false)
        }
        if conforms(provider, to: .audio) {
            return .media(node: "audio", isImage: false)
        }
        if let ext = provider.suggestedName.map({ ($0 as NSString).pathExtension }),
            !ext.isEmpty,
            let suggestedType = UTType(filenameExtension: ext.lowercased())
        {
            if suggestedType.conforms(to: .pdf) { return .media(node: "pdf", isImage: false) }
            if suggestedType.conforms(to: .image), !suggestedType.conforms(to: .svg) {
                return .media(node: "image", isImage: true)
            }
            if suggestedType.conforms(to: .movie) || suggestedType.conforms(to: .video) {
                return .media(node: "video", isImage: false)
            }
            if suggestedType.conforms(to: .audio) {
                return .media(node: "audio", isImage: false)
            }
        }
        if conforms(provider, to: .fileURL) || conforms(provider, to: .archive) || hasNonTextDataType(provider) {
            return .file
        }
        if treatNamedTextAsFile,
            conforms(provider, to: .plainText),
            !conforms(provider, to: .url),
            let name = provider.suggestedName,
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .file
        }
        return .ignore
    }

    private static func isBareDirectory(_ provider: NSItemProvider) -> Bool {
        guard conforms(provider, to: .directory) || conforms(provider, to: .folder) else { return false }
        if conforms(provider, to: .package) { return false }
        let hasKnownFilePayload =
            conforms(provider, to: .pdf)
            || conforms(provider, to: .image)
            || conforms(provider, to: .audiovisualContent)
            || conforms(provider, to: .archive)
        return !hasKnownFilePayload
    }

    private static func isVectorOnlySVG(_ provider: NSItemProvider) -> Bool {
        guard conforms(provider, to: .svg) else { return false }
        let rasterTypes: [UTType] = [.png, .jpeg, .heic, .gif, .tiff, .bmp, .webP, .rawImage]
        return !rasterTypes.contains { conforms(provider, to: $0) }
    }

    private static func hasNonTextDataType(_ provider: NSItemProvider) -> Bool {
        for identifier in provider.registeredTypeIdentifiers {
            guard let type = UTType(identifier) else { continue }
            if type == .fileURL || type.conforms(to: .fileURL) { return true }
            if type.conforms(to: .url) || type.conforms(to: .text) || type.conforms(to: .directory) { continue }
            if type.conforms(to: .data) || type.conforms(to: .content) || type.conforms(to: .item) {
                return true
            }
        }
        return false
    }

    private static func conforms(_ provider: NSItemProvider, to type: UTType) -> Bool {
        provider.hasItemConformingToTypeIdentifier(type.identifier)
    }

    // MARK: - Block Range Resolution

    /// Returns the index range `start..<end` in `blocks` for the enclosing
    /// `depth == 0` block (root or column-root) containing `index`.
    static func rootBlockRange(at index: Int, in blocks: [BlockSnapshot]) -> Range<Int>? {
        guard blocks.indices.contains(index) else { return nil }
        var start = index
        while start > 0 && blocks[start].depth > 0 {
            start -= 1
        }
        var end = start + 1
        while end < blocks.count && blocks[end].depth > 0 {
            end += 1
        }
        return start..<end
    }

    static func isEmptyRootParagraph(range: Range<Int>, in blocks: [BlockSnapshot]) -> Bool {
        guard range.count == 1 else { return false }
        let block = blocks[range.lowerBound]
        guard block.node == "paragraph" else { return false }
        return block.runs.allSatisfy { $0.inlineObject == nil && $0.text.isEmpty }
    }

    // MARK: - Synchronous Drop/Paste Staging

    struct StagedItem: Sendable {
        let node: String
        let isPhoto: Bool
        let stagingURL: URL?
        let exceededByteLimit: Bool

        var source: NativeMediaUploads.Source {
            if isPhoto {
                return .photo { [stagingURL, exceededByteLimit] in
                    if exceededByteLimit { throw AttachmentImportError.tooLarge }
                    guard let stagingURL else { throw AttachmentImportError.unreadable }
                    defer { removeStagingURL(stagingURL) }
                    let file = try loadPickedAttachmentFile(
                        at: stagingURL, byteLimit: attachmentImportByteLimit, allowStagingRoot: true)
                    return file.data
                }
            }
            return .file { [stagingURL, exceededByteLimit] in
                if exceededByteLimit { throw AttachmentImportError.tooLarge }
                guard let stagingURL else { throw AttachmentImportError.unreadable }
                defer { removeStagingURL(stagingURL) }
                return try loadPickedAttachmentFile(
                    at: stagingURL, byteLimit: attachmentImportByteLimit, allowStagingRoot: true)
            }
        }

        func cleanupStagingFile() {
            guard let stagingURL else { return }
            NativeMediaDropPaste.removeStagingURL(stagingURL)
        }
    }

    final class StagedBatch: Sendable {
        private struct State: Sendable {
            var results: [StagedItem?]
            var remaining: Int
            var continuations: [CheckedContinuation<[StagedItem], Never>] = []
            var cleanedUp = false
        }

        private let batchDirectory: URL
        private let state: Mutex<State>

        init(count: Int, batchDirectory: URL) {
            self.batchDirectory = batchDirectory
            self.state = Mutex(State(results: Array(repeating: nil, count: count), remaining: count))
        }

        func finish(index: Int, item: StagedItem) {
            var removeFileURL: URL?
            var removeItemDir: URL?
            var removeBatchDir: URL?
            let toResume: ([StagedItem], [CheckedContinuation<[StagedItem], Never>])? = state.withLock { state in
                guard state.results.indices.contains(index), state.results[index] == nil else { return nil }
                if state.cleanedUp {
                    removeFileURL = item.stagingURL
                    removeBatchDir = batchDirectory
                } else if item.stagingURL == nil {
                    removeItemDir = batchDirectory.appendingPathComponent("\(index)", isDirectory: true)
                }
                state.results[index] = item
                state.remaining -= 1
                guard state.remaining == 0 else { return nil }
                let resolved = state.results.enumerated().map { idx, value in
                    value ?? StagedItem(node: "file", isPhoto: false, stagingURL: nil, exceededByteLimit: false)
                }
                let waiters = state.continuations
                state.continuations.removeAll()
                return (resolved, waiters)
            }
            if let removeFileURL {
                try? FileManager.default.removeItem(at: removeFileURL)
            }
            if let removeItemDir {
                if let contents = try? FileManager.default.contentsOfDirectory(atPath: removeItemDir.path),
                    contents.isEmpty
                {
                    try? FileManager.default.removeItem(at: removeItemDir)
                }
            }
            if let removeBatchDir {
                try? FileManager.default.removeItem(at: removeBatchDir)
            }
            if let (resolved, waiters) = toResume {
                for continuation in waiters {
                    continuation.resume(returning: resolved)
                }
            }
        }

        func waitAll() async -> [StagedItem] {
            await withCheckedContinuation { continuation in
                let ready: [StagedItem]? = state.withLock { state in
                    if state.remaining == 0 {
                        return state.results.map {
                            $0 ?? StagedItem(node: "file", isPhoto: false, stagingURL: nil, exceededByteLimit: false)
                        }
                    }
                    state.continuations.append(continuation)
                    return nil
                }
                if let ready {
                    continuation.resume(returning: ready)
                }
            }
        }

        func cleanupAll() {
            let dir = batchDirectory
            state.withLock { state in
                state.cleanedUp = true
            }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    static func stagingRootDirectory() -> URL {
        let caches =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("MediaDropStaging", isDirectory: true)
    }

    static func removeStagingRoot() {
        try? FileManager.default.removeItem(at: stagingRootDirectory())
    }

    /// Synchronously initiates `NSItemProvider` file/data loads into a
    /// non-backed-up staging directory so cross-app `UIDropSession` security
    /// scopes stay valid before `performDrop` returns.
    static func stage(
        providers: [(provider: NSItemProvider, kind: PayloadKind)],
        stagingRoot: URL? = nil,
        byteLimit: Int = attachmentImportByteLimit
    ) -> StagedBatch {
        let batchDir = (stagingRoot ?? stagingRootDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        ensureNonBackedUpDirectory(batchDir)

        let batch = StagedBatch(count: providers.count, batchDirectory: batchDir)
        guard !providers.isEmpty else {
            try? FileManager.default.removeItem(at: batchDir)
            return batch
        }

        for (index, entry) in providers.enumerated() {
            let provider = entry.provider
            let kind = entry.kind
            let node = kind.node ?? "file"
            let isPhoto = kind.isPhoto
            let itemDir = batchDir.appendingPathComponent("\(index)", isDirectory: true)
            ensureNonBackedUpDirectory(itemDir)

            let typeID = preferredTypeIdentifier(for: provider, kind: kind)
            loadFileThenData(
                provider: provider, typeID: typeID, node: node, isPhoto: isPhoto,
                destinationDir: itemDir, byteLimit: byteLimit, index: index, batch: batch)
        }
        return batch
    }

    private static func loadFileThenData(
        provider: NSItemProvider,
        typeID: String,
        node: String,
        isPhoto: Bool,
        destinationDir: URL,
        byteLimit: Int,
        index: Int,
        batch: StagedBatch
    ) {
        if UTType(typeID)?.conforms(to: .fileURL) != true {
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { tempURL, _ in
                if let tempURL {
                    let result = stageFromFileURL(
                        tempURL, node: node, isPhoto: isPhoto, suggestedName: provider.suggestedName,
                        preferredTypeIdentifier: typeID, destinationDir: destinationDir, byteLimit: byteLimit)
                    if result.stagingURL != nil || result.exceededByteLimit {
                        batch.finish(index: index, item: result)
                        return
                    }
                }
                loadFileURLOrDataFallback(
                    provider: provider, typeID: typeID, node: node, isPhoto: isPhoto,
                    destinationDir: destinationDir, byteLimit: byteLimit, index: index, batch: batch)
            }
            return
        }

        loadFileURLOrDataFallback(
            provider: provider, typeID: typeID, node: node, isPhoto: isPhoto,
            destinationDir: destinationDir, byteLimit: byteLimit, index: index, batch: batch)
    }

    private static func loadFileURLOrDataFallback(
        provider: NSItemProvider,
        typeID: String,
        node: String,
        isPhoto: Bool,
        destinationDir: URL,
        byteLimit: Int,
        index: Int,
        batch: StagedBatch
    ) {
        // Fallback 1: explicit file-url representation (validated against symlinks & app container).
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
            provider.canLoadObject(ofClass: URL.self)
        {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    let result = stageFromFileURL(
                        url, node: node, isPhoto: isPhoto, suggestedName: provider.suggestedName,
                        preferredTypeIdentifier: typeID, destinationDir: destinationDir, byteLimit: byteLimit)
                    batch.finish(index: index, item: result)
                    return
                }
                loadDataFallback(
                    provider: provider, typeID: typeID, node: node, isPhoto: isPhoto,
                    destinationDir: destinationDir, byteLimit: byteLimit, index: index, batch: batch)
            }
            return
        }

        // Fallback 2: in-memory bitmap or data representation (e.g. copied UIImage).
        loadDataFallback(
            provider: provider, typeID: typeID, node: node, isPhoto: isPhoto,
            destinationDir: destinationDir, byteLimit: byteLimit, index: index, batch: batch)
    }

    private static func loadDataFallback(
        provider: NSItemProvider,
        typeID: String,
        node: String,
        isPhoto: Bool,
        destinationDir: URL,
        byteLimit: Int,
        index: Int,
        batch: StagedBatch
    ) {
        let dataTypeID = preferredDataTypeIdentifier(for: provider, primary: typeID, isPhoto: isPhoto)
        guard let dataType = UTType(dataTypeID),
            !dataType.conforms(to: .url),
            !dataType.conforms(to: .directory)
        else {
            batch.finish(
                index: index,
                item: StagedItem(node: node, isPhoto: isPhoto, stagingURL: nil, exceededByteLimit: false))
            return
        }
        provider.loadDataRepresentation(forTypeIdentifier: dataTypeID) { data, _ in
            guard let data else {
                batch.finish(
                    index: index,
                    item: StagedItem(node: node, isPhoto: isPhoto, stagingURL: nil, exceededByteLimit: false))
                return
            }
            guard data.count <= byteLimit else {
                batch.finish(
                    index: index,
                    item: StagedItem(node: node, isPhoto: isPhoto, stagingURL: nil, exceededByteLimit: true))
                return
            }
            let fileName = resolvedFileName(
                sourceURL: nil, suggestedName: provider.suggestedName, typeIdentifier: dataTypeID, node: node)
            let targetURL = destinationDir.appendingPathComponent(fileName)
            do {
                try data.write(to: targetURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                excludeFromBackup(targetURL)
                batch.finish(
                    index: index,
                    item: StagedItem(node: node, isPhoto: isPhoto, stagingURL: targetURL, exceededByteLimit: false))
            } catch {
                batch.finish(
                    index: index,
                    item: StagedItem(node: node, isPhoto: isPhoto, stagingURL: nil, exceededByteLimit: false))
            }
        }
    }

    static func stageFromFileURL(
        _ sourceURL: URL,
        node: String,
        isPhoto: Bool,
        suggestedName: String?,
        preferredTypeIdentifier: String,
        destinationDir: URL,
        byteLimit: Int,
        onValidated: (() -> Void)? = nil
    ) -> StagedItem {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let rejected = StagedItem(node: node, isPhoto: isPhoto, stagingURL: nil, exceededByteLimit: false)
        guard sourceURL.isFileURL,
            !sourceURL.hasDirectoryPath,
            isAllowedImportSourceURL(sourceURL, allowStagingRoot: false)
        else {
            return rejected
        }

        // Open once without following symlinks or blocking on FIFOs/devices.
        let srcFD = Darwin.open(sourceURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard srcFD >= 0 else { return rejected }
        defer { Darwin.close(srcFD) }

        var st = stat()
        guard Darwin.fstat(srcFD, &st) == 0,
            (st.st_mode & S_IFMT) == S_IFREG,
            st.st_size >= 0
        else {
            return rejected
        }
        if st.st_size > Int64(byteLimit) {
            return StagedItem(node: node, isPhoto: isPhoto, stagingURL: nil, exceededByteLimit: true)
        }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fcntl(srcFD, F_GETPATH, &pathBuffer) == 0 else { return rejected }
        pathBuffer[pathBuffer.count - 1] = 0
        let realPath = String(cString: pathBuffer)
        guard !realPath.isEmpty else { return rejected }
        let realURL = URL(fileURLWithPath: realPath)
        guard isAllowedImportSourceURL(realURL, allowStagingRoot: false) else { return rejected }

        onValidated?()

        let fileName = resolvedFileName(
            sourceURL: sourceURL, suggestedName: suggestedName, typeIdentifier: preferredTypeIdentifier, node: node)
        let targetURL = destinationDir.appendingPathComponent(fileName)

        let dstFD = Darwin.open(targetURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard dstFD >= 0 else { return rejected }

        var dstOpen = true
        defer {
            if dstOpen { Darwin.close(dstFD) }
        }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var totalBytes = 0
        while true {
            let bytesRead = Darwin.read(srcFD, &buffer, buffer.count)
            if bytesRead < 0 {
                if errno == EINTR { continue }
                Darwin.close(dstFD)
                dstOpen = false
                try? FileManager.default.removeItem(at: targetURL)
                return rejected
            }
            if bytesRead == 0 { break }
            if totalBytes + bytesRead > byteLimit {
                Darwin.close(dstFD)
                dstOpen = false
                try? FileManager.default.removeItem(at: targetURL)
                return StagedItem(node: node, isPhoto: isPhoto, stagingURL: nil, exceededByteLimit: true)
            }
            totalBytes += bytesRead

            var offset = 0
            while offset < bytesRead {
                let written = buffer.withUnsafeBytes { raw in
                    Darwin.write(dstFD, raw.baseAddress!.advanced(by: offset), bytesRead - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    Darwin.close(dstFD)
                    dstOpen = false
                    try? FileManager.default.removeItem(at: targetURL)
                    return rejected
                }
                if written == 0 {
                    Darwin.close(dstFD)
                    dstOpen = false
                    try? FileManager.default.removeItem(at: targetURL)
                    return rejected
                }
                offset += written
            }
        }

        Darwin.close(dstFD)
        dstOpen = false

        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: targetURL.path)
        excludeFromBackup(targetURL)

        switch validateRegularImportFile(at: targetURL, byteLimit: byteLimit, allowStagingRoot: true) {
        case .valid:
            return StagedItem(node: node, isPhoto: isPhoto, stagingURL: targetURL, exceededByteLimit: false)
        case .tooLarge:
            try? FileManager.default.removeItem(at: targetURL)
            return StagedItem(node: node, isPhoto: isPhoto, stagingURL: nil, exceededByteLimit: true)
        case .rejected:
            try? FileManager.default.removeItem(at: targetURL)
            return rejected
        }
    }

    private static func preferredTypeIdentifier(for provider: NSItemProvider, kind: PayloadKind) -> String {
        switch kind {
        case .media("pdf", _):
            return firstMatchingIdentifier(in: provider, conformingTo: .pdf)
                ?? firstNonURLDataIdentifier(in: provider)
                ?? UTType.pdf.identifier
        case .media("image", _):
            let rasterCandidates: [UTType] = [.heic, .jpeg, .png, .gif, .webP, .tiff, .bmp, .image]
            for type in rasterCandidates {
                if let match = firstMatchingIdentifier(in: provider, conformingTo: type),
                    UTType(match)?.conforms(to: .svg) != true
                {
                    return match
                }
            }
            return firstNonURLDataIdentifier(in: provider) ?? UTType.image.identifier
        case .media("video", _):
            return firstMatchingIdentifier(in: provider, conformingTo: .movie)
                ?? firstMatchingIdentifier(in: provider, conformingTo: .video)
                ?? firstNonURLDataIdentifier(in: provider)
                ?? UTType.movie.identifier
        case .media("audio", _):
            return firstMatchingIdentifier(in: provider, conformingTo: .audio)
                ?? firstNonURLDataIdentifier(in: provider)
                ?? UTType.audio.identifier
        case .media(let node, _):
            _ = node
            return provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
        case .file, .ignore:
            if let svg = firstMatchingIdentifier(in: provider, conformingTo: .svg) { return svg }
            return firstNonURLDataIdentifier(in: provider)
                ?? provider.registeredTypeIdentifiers.first
                ?? UTType.data.identifier
        }
    }

    private static func firstNonURLDataIdentifier(in provider: NSItemProvider) -> String? {
        for identifier in provider.registeredTypeIdentifiers {
            guard let type = UTType(identifier) else { continue }
            if type.conforms(to: .url) || type.conforms(to: .directory) { continue }
            if type.conforms(to: .data) || type.conforms(to: .content) || type.conforms(to: .item) {
                return identifier
            }
        }
        return nil
    }

    private static func preferredDataTypeIdentifier(
        for provider: NSItemProvider,
        primary: String,
        isPhoto: Bool
    ) -> String {
        if UTType(primary)?.conforms(to: .url) == true {
            if isPhoto, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                return UTType.image.identifier
            }
            for identifier in provider.registeredTypeIdentifiers where identifier != primary {
                if let type = UTType(identifier), !type.conforms(to: .url), !type.conforms(to: .directory) {
                    return identifier
                }
            }
        }
        return primary
    }

    private static func firstMatchingIdentifier(in provider: NSItemProvider, conformingTo type: UTType) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            UTType(identifier)?.conforms(to: type) == true
        }
    }

    private static func resolvedFileName(
        sourceURL: URL?,
        suggestedName: String?,
        typeIdentifier: String,
        node: String
    ) -> String {
        let baseName: String =
            if let sourceName = sourceURL?.lastPathComponent, !sourceName.isEmpty {
                sourceName
            } else if let suggestedName, !suggestedName.isEmpty {
                suggestedName
            } else {
                node
            }

        let sourceExt = sourceURL?.pathExtension ?? ""
        let currentExt = (baseName as NSString).pathExtension
        if currentExt.isEmpty {
            let ext =
                (!sourceExt.isEmpty ? sourceExt : nil)
                ?? UTType(typeIdentifier)?.preferredFilenameExtension
                ?? defaultExtension(for: node)
            if let ext, !ext.isEmpty {
                return sanitizedAttachmentFileName("\(baseName).\(ext)")
            }
        }
        return sanitizedAttachmentFileName(baseName)
    }

    private static func defaultExtension(for node: String) -> String? {
        switch node {
        case "image": "jpg"
        case "video": "mp4"
        case "audio": "m4a"
        case "pdf": "pdf"
        default: nil
        }
    }

    private static func ensureNonBackedUpDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        excludeFromBackup(url)
    }

    private static func excludeFromBackup(_ url: URL) {
        var copy = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? copy.setResourceValues(values)
    }

    private static func removeStagingURL(_ fileURL: URL) {
        let itemDir = fileURL.deletingLastPathComponent()
        let batchDir = itemDir.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: fileURL)
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: itemDir.path), contents.isEmpty {
            try? FileManager.default.removeItem(at: itemDir)
        }
        if let batchContents = try? FileManager.default.contentsOfDirectory(atPath: batchDir.path),
            batchContents.isEmpty
        {
            try? FileManager.default.removeItem(at: batchDir)
        }
    }
}

// MARK: - Drop Target & Controller

enum MediaDropTarget: Equatable, Sendable {
    case replace(blockID: String)
    case before(blockID: String, indicatorY: CGFloat)
    case after(blockID: String, indicatorY: CGFloat)

    var blockID: String {
        switch self {
        case .replace(let id), .before(let id, _), .after(let id, _):
            id
        }
    }

    var placement: MediaInsertPlacement {
        switch self {
        case .replace: .replaceOrAfter
        case .before: .before
        case .after: .after
        }
    }
}

/// Manages drag-and-drop hit-testing, drop indicator chrome, and
/// `UIDropInteractionDelegate` / `UITextDropDelegate` routing on `NativeTextView`.
@MainActor
final class NativeMediaDropController: NSObject, UIDropInteractionDelegate, UITextDropDelegate {
    weak var textView: NativeTextView?
    private(set) var currentTarget: MediaDropTarget?

    private let lineIndicator: UIView = {
        let view = UIView()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.layer.cornerRadius = 1
        return view
    }()

    private let replaceIndicator: UIView = {
        let view = UIView()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.layer.borderWidth = 2
        view.layer.cornerRadius = 6
        return view
    }()

    var isShowingDropIndicator: Bool {
        !lineIndicator.isHidden || !replaceIndicator.isHidden
    }

    init(textView: NativeTextView) {
        self.textView = textView
        super.init()
        textView.addSubview(lineIndicator)
        textView.addSubview(replaceIndicator)
    }

    func bringIndicatorsToFront(in view: NativeTextView) {
        view.bringSubviewToFront(replaceIndicator)
        view.bringSubviewToFront(lineIndicator)
    }

    func hideIndicator() {
        currentTarget = nil
        lineIndicator.isHidden = true
        replaceIndicator.isHidden = true
    }

    // MARK: - TextKit 2 Hit-Testing

    struct HitTestResult: Equatable {
        let target: MediaDropTarget
        let highlightRect: CGRect?
    }

    func hitTestDrop(at point: CGPoint) -> HitTestResult? {
        guard let textView,
            let surface = textView.blockControls.surface,
            let layoutManager = textView.textLayoutManager,
            let contentManager = layoutManager.textContentManager
        else { return nil }

        let blocks = surface.blocks
        let entries = surface.rangeIndex.entries
        guard !blocks.isEmpty, blocks.count == entries.count else { return nil }

        let inset = textView.textContainerInset
        let containerPoint = CGPoint(x: point.x - inset.left, y: point.y - inset.top)
        let docStart = contentManager.documentRange.location

        // Check first block boundary (above all fragments).
        let firstRootEnd = NativeMediaDropPaste.rootBlockRange(at: 0, in: blocks)?.upperBound ?? 1
        if let firstFrame = fragmentFrame(
            forBlockAt: 0, entries: entries, contentManager: contentManager, layoutManager: layoutManager,
            docStart: docStart)
        {
            if containerPoint.y < firstFrame.minY {
                if NativeMediaDropPaste.isEmptyRootParagraph(range: 0..<firstRootEnd, in: blocks) {
                    return HitTestResult(
                        target: .replace(blockID: blocks[0].id),
                        highlightRect: viewRect(forContainerRect: firstFrame, in: textView, inset: inset))
                }
                return HitTestResult(
                    target: .before(blockID: blocks[0].id, indicatorY: inset.top + firstFrame.minY),
                    highlightRect: nil)
            }
        }

        // Check last root block boundary (below all fragments).
        if let lastVisibleEntryIndex = entries.indices.last(where: { !surface.isHidden(position: $0) }),
            let lastRootRange = NativeMediaDropPaste.rootBlockRange(at: lastVisibleEntryIndex, in: blocks),
            let lastFrame = fragmentFrame(
                forBlockAt: lastVisibleEntryIndex, entries: entries, contentManager: contentManager,
                layoutManager: layoutManager, docStart: docStart)
        {
            if containerPoint.y > lastFrame.maxY {
                let rootID = blocks[lastRootRange.lowerBound].id
                if NativeMediaDropPaste.isEmptyRootParagraph(range: lastRootRange, in: blocks) {
                    let rect = spanRect(
                        for: lastRootRange, entries: entries, surface: surface, textView: textView,
                        contentManager: contentManager, layoutManager: layoutManager, docStart: docStart, inset: inset)
                    return HitTestResult(target: .replace(blockID: rootID), highlightRect: rect)
                }
                return HitTestResult(
                    target: .after(blockID: rootID, indicatorY: inset.top + lastFrame.maxY),
                    highlightRect: nil)
            }
        }

        // Hit-test the layout fragment containing `containerPoint`.
        if let fragment = layoutManager.textLayoutFragment(for: containerPoint) {
            let utf16Offset = contentManager.offset(from: docStart, to: fragment.rangeInElement.location)
            if let entry = surface.rangeIndex.entry(atUTF16: max(0, utf16Offset)),
                let index = entries.firstIndex(where: { $0.blockID == entry.blockID }),
                let rootRange = NativeMediaDropPaste.rootBlockRange(at: index, in: blocks)
            {
                let rootBlock = blocks[rootRange.lowerBound]
                if let span = spanContainerFrame(
                    for: rootRange, entries: entries, surface: surface, contentManager: contentManager,
                    layoutManager: layoutManager, docStart: docStart)
                {
                    if NativeMediaDropPaste.isEmptyRootParagraph(range: rootRange, in: blocks) {
                        return HitTestResult(
                            target: .replace(blockID: rootBlock.id),
                            highlightRect: viewRect(forContainerRect: span, in: textView, inset: inset))
                    }
                    let midpointY = (span.minY + span.maxY) / 2
                    if containerPoint.y < midpointY {
                        return HitTestResult(
                            target: .before(blockID: rootBlock.id, indicatorY: inset.top + span.minY),
                            highlightRect: nil)
                    } else {
                        return HitTestResult(
                            target: .after(blockID: rootBlock.id, indicatorY: inset.top + span.maxY),
                            highlightRect: nil)
                    }
                }
            }
        }

        // Fallback to last root block if layout isn't populated yet.
        guard let lastRootRange = NativeMediaDropPaste.rootBlockRange(at: blocks.count - 1, in: blocks) else {
            return nil
        }
        let rootID = blocks[lastRootRange.lowerBound].id
        if NativeMediaDropPaste.isEmptyRootParagraph(range: lastRootRange, in: blocks) {
            return HitTestResult(target: .replace(blockID: rootID), highlightRect: nil)
        }
        let fallbackY = max(inset.top, textView.contentSize.height - inset.bottom)
        return HitTestResult(target: .after(blockID: rootID, indicatorY: fallbackY), highlightRect: nil)
    }

    private func fragmentFrame(
        forBlockAt index: Int,
        entries: [ProjectionRangeIndex.Entry],
        contentManager: NSTextContentManager,
        layoutManager: NSTextLayoutManager,
        docStart: NSTextLocation
    ) -> CGRect? {
        guard entries.indices.contains(index) else { return nil }
        let offset = entries[index].range.location
        guard let loc = contentManager.location(docStart, offsetBy: offset),
            let fragment = layoutManager.textLayoutFragment(for: loc)
        else { return nil }
        return fragment.layoutFragmentFrame
    }

    private func spanContainerFrame(
        for rootRange: Range<Int>,
        entries: [ProjectionRangeIndex.Entry],
        surface: NativeTextSurface,
        contentManager: NSTextContentManager,
        layoutManager: NSTextLayoutManager,
        docStart: NSTextLocation
    ) -> CGRect? {
        let firstIdx = rootRange.lowerBound
        let lastIdx =
            rootRange.reversed().first(where: { !surface.isHidden(position: $0) })
            ?? rootRange.lowerBound
        guard
            let firstFrame = fragmentFrame(
                forBlockAt: firstIdx, entries: entries, contentManager: contentManager, layoutManager: layoutManager,
                docStart: docStart)
        else { return nil }
        let lastFrame =
            lastIdx == firstIdx
            ? firstFrame
            : (fragmentFrame(
                forBlockAt: lastIdx, entries: entries, contentManager: contentManager, layoutManager: layoutManager,
                docStart: docStart) ?? firstFrame)
        return firstFrame.union(lastFrame)
    }

    private func spanRect(
        for rootRange: Range<Int>,
        entries: [ProjectionRangeIndex.Entry],
        surface: NativeTextSurface,
        textView: NativeTextView,
        contentManager: NSTextContentManager,
        layoutManager: NSTextLayoutManager,
        docStart: NSTextLocation,
        inset: UIEdgeInsets
    ) -> CGRect? {
        guard
            let containerRect = spanContainerFrame(
                for: rootRange, entries: entries, surface: surface, contentManager: contentManager,
                layoutManager: layoutManager, docStart: docStart)
        else { return nil }
        return viewRect(forContainerRect: containerRect, in: textView, inset: inset)
    }

    private func viewRect(forContainerRect rect: CGRect, in textView: NativeTextView, inset: UIEdgeInsets) -> CGRect {
        let width = max(44, textView.bounds.width - inset.left - inset.right)
        return CGRect(
            x: inset.left,
            y: inset.top + rect.minY,
            width: width,
            height: max(28, rect.height)
        )
    }

    private func showIndicator(for result: HitTestResult, in textView: NativeTextView) {
        let accent = textView.blockControls.color(\.brandFill)
        currentTarget = result.target
        let inset = textView.textContainerInset
        let width = max(44, textView.bounds.width - inset.left - inset.right)

        switch result.target {
        case .before(_, let indicatorY), .after(_, let indicatorY):
            replaceIndicator.isHidden = true
            lineIndicator.backgroundColor = accent
            lineIndicator.frame = CGRect(x: inset.left, y: round(indicatorY - 1), width: width, height: 2)
            lineIndicator.isHidden = false
        case .replace:
            lineIndicator.isHidden = true
            if let rect = result.highlightRect {
                replaceIndicator.layer.borderColor = accent.cgColor
                replaceIndicator.frame = rect.insetBy(dx: -4, dy: -2)
                replaceIndicator.isHidden = false
            } else {
                replaceIndicator.isHidden = true
            }
        }
        bringIndicatorsToFront(in: textView)
    }

    // MARK: - UIDropInteractionDelegate

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        guard session.localDragSession == nil else { return false }
        return NativeMediaDropPaste.containsMediaItems(in: session)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        guard let textView,
            let coordinator = textView.inputCoordinator,
            coordinator.canAcceptMediaDrop,
            NativeMediaDropPaste.containsMediaItems(in: session)
        else {
            hideIndicator()
            return UIDropProposal(operation: .forbidden)
        }

        let point = session.location(in: textView)
        guard let hit = hitTestDrop(at: point) else {
            hideIndicator()
            return UIDropProposal(operation: .forbidden)
        }
        showIndicator(for: hit, in: textView)
        return UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
        hideIndicator()
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
        hideIndicator()
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let textView,
            let coordinator = textView.inputCoordinator
        else {
            hideIndicator()
            return
        }
        let point = session.location(in: textView)
        let target = currentTarget ?? hitTestDrop(at: point)?.target
        hideIndicator()
        guard let target else { return }

        let providers = NativeMediaDropPaste.mediaProviders(from: session.items.map { $0.itemProvider })
        guard !providers.isEmpty else { return }
        _ = coordinator.handleMediaDrop(providers, target: target)
    }

    // MARK: - UITextDropDelegate

    func textDroppableView(
        _ textDroppableView: UIView & UITextDroppable,
        proposalForDrop drop: UITextDropRequest
    ) -> UITextDropProposal {
        if drop.dropSession.localDragSession == nil,
            NativeMediaDropPaste.containsMediaItems(in: drop.dropSession)
        {
            return UITextDropProposal(operation: .forbidden)
        }
        guard textView?.inputCoordinator?.canEditForTextDrop == true else {
            return UITextDropProposal(operation: .forbidden)
        }
        return UITextDropProposal(operation: .copy)
    }
}
