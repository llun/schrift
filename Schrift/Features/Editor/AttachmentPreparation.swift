import Foundation
import UniformTypeIdentifiers

/// A picked file, ready to upload.
struct PreparedAttachmentFile: Equatable, Sendable {
    /// Sanitized — safe to interpolate into a multipart header *and* to read
    /// back out of a markdown link label. Never the raw picked name.
    let fileName: String
    let contentType: String
    let data: Data
}

enum AttachmentImportError: Error, Equatable {
    case tooLarge
    case unreadable
}

/// Refused before a byte is read, not after.
///
/// The server enforces its own cap (10 MB by default), so this is not the
/// access-control limit — it is what keeps `Data(contentsOf:)` from taking the
/// editor down on a file the user picked by accident. Set well above the server
/// default so the server's own error is what a user normally sees.
let attachmentImportByteLimit = 50 * 1024 * 1024

/// Makes a picked file's name safe for the two places it will be interpolated.
///
/// Two independent requirements, and the union of them is what this enforces:
///   * **multipart**: no quote, CR or LF, or the upload's `Content-Disposition`
///     header could be broken out of (`isSafeMultipartToken`);
///   * **markdown**: no `[`, `]`, `(`, `)`, or newline, or the `[name](url)`
///     line the block serializes to would not parse back as one link — the
///     insert would then fail its own verification, or worse, round-trip into
///     something else.
///
/// Path separators (`/`, `\`, `:`) go too. Nothing downstream builds a path from
/// this name — the cache is keyed on the server's own ids — but the server does
/// store it, and a name that reads as a path is a hazard waiting for the first
/// consumer that forgets.
///
/// Anything else the user typed is kept: spaces, unicode, emoji, `&`, `#` are
/// all fine in both contexts. An empty or all-stripped name falls back to
/// "file", because a nameless attachment is legal but unhelpful.
func sanitizedAttachmentFileName(_ name: String) -> String {
    let forbidden: Set<Character> = ["\"", "[", "]", "(", ")", "/", "\\", ":"]
    var cleaned = String(
        name.unicodeScalars
            .filter { !CharacterSet.newlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
            .map(Character.init)
            .filter { !forbidden.contains($0) }
    )
    // A leading dot would make the file hidden and, more to the point, is what a
    // "..\u{2026}" style name reduces to once separators are stripped.
    while cleaned.hasPrefix(".") { cleaned.removeFirst() }
    cleaned = cleaned.trimmingCharacters(in: .whitespaces)
    // Long enough for any real name; short enough that the card and the markdown
    // line stay readable. **The extension is preserved across the cap**: the
    // server derives the stored key's extension from this name, and a key with
    // no extension makes `parseAttachmentLink` decline — so `addsAttachment`
    // would count zero and the insert would fail *after* a successful upload,
    // leaving an orphan on the server.
    if cleaned.count > 120 {
        let dot = cleaned.lastIndex(of: ".")
        let ext = dot.map { String(cleaned[cleaned.index(after: $0)...]) } ?? ""
        if !ext.isEmpty, ext.count < 20 {
            cleaned = String(cleaned.prefix(120 - ext.count - 1)) + "." + ext
        } else {
            cleaned = String(cleaned.prefix(120))
        }
    }
    return cleaned.isEmpty ? "file" : cleaned
}

/// The MIME type to upload under. The server sniffs the real type anyway and
/// stores a mismatch under an `-unsafe` key, so this only has to be honest, not
/// authoritative.
func attachmentContentType(forFileExtension fileExtension: String) -> String {
    guard !fileExtension.isEmpty,
        let type = UTType(filenameExtension: fileExtension.lowercased()),
        let mime = type.preferredMIMEType
    else { return "application/octet-stream" }
    return mime
}

enum ValidatedImportFile {
    case valid
    case tooLarge
    case rejected
}

private func isPath(_ path: String, insideRoot rootPath: String) -> Bool {
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    return path == rootPath || path.hasPrefix(prefix)
}

private func isURL(_ candidate: URL, inside root: URL) -> Bool {
    let candidatePaths = [
        candidate.standardizedFileURL.path,
        candidate.resolvingSymlinksInPath().standardizedFileURL.path,
    ]
    let rootPaths = [
        root.standardizedFileURL.path,
        root.resolvingSymlinksInPath().standardizedFileURL.path,
    ]
    return candidatePaths.contains { cPath in
        rootPaths.contains { rPath in isPath(cPath, insideRoot: rPath) }
    }
}

private func isURLFullyInside(_ candidate: URL, root: URL) -> Bool {
    let rawCandidate = candidate.standardizedFileURL.path
    let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL.path
    let rawRoot = root.standardizedFileURL.path
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    let rawMatches = isPath(rawCandidate, insideRoot: rawRoot) || isPath(rawCandidate, insideRoot: resolvedRoot)
    let resolvedMatches =
        isPath(resolvedCandidate, insideRoot: rawRoot) || isPath(resolvedCandidate, insideRoot: resolvedRoot)
    return rawMatches && resolvedMatches
}

/// Refuses files inside the app bundle, `Library/`, `Documents/`, or
/// `MediaDropStaging` (unless `allowStagingRoot` is explicitly enabled for
/// reading a previously staged drop/paste copy).
func isAllowedImportSourceURL(_ url: URL, allowStagingRoot: Bool = false) -> Bool {
    guard url.isFileURL else { return false }
    let stagingRoot = NativeMediaDropPaste.stagingRootDirectory()
    if allowStagingRoot, isURLFullyInside(url, root: stagingRoot) {
        return true
    }

    let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    var forbiddenRoots: [URL] = [
        Bundle.main.bundleURL,
        home.appendingPathComponent("Library", isDirectory: true),
        home.appendingPathComponent("Documents", isDirectory: true),
        stagingRoot,
    ]
    forbiddenRoots.append(contentsOf: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask))
    forbiddenRoots.append(contentsOf: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask))

    return !forbiddenRoots.contains { isURL(url, inside: $0) }
}

/// Validates that `url` is an allowed, non-symlink regular file within `byteLimit`.
func validateRegularImportFile(
    at url: URL,
    byteLimit: Int,
    allowStagingRoot: Bool = false
) -> ValidatedImportFile {
    guard url.isFileURL, !url.hasDirectoryPath, isAllowedImportSourceURL(url, allowStagingRoot: allowStagingRoot) else {
        return .rejected
    }
    var fresh = URL(fileURLWithPath: url.path)
    fresh.removeAllCachedResourceValues()
    guard
        let values = try? fresh.resourceValues(forKeys: [
            .isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey,
        ]),
        values.isSymbolicLink != true,
        values.isRegularFile == true,
        values.isDirectory != true
    else {
        return .rejected
    }
    if let size = values.fileSize, size > byteLimit {
        return .tooLarge
    }
    return .valid
}

private func readRegularFileBytes(at url: URL, byteLimit: Int) throws -> Data {
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw AttachmentImportError.unreadable }
    defer { Darwin.close(fd) }

    var st = stat()
    guard Darwin.fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
        throw AttachmentImportError.unreadable
    }
    if st.st_size > Int64(byteLimit) {
        throw AttachmentImportError.tooLarge
    }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count < 0 {
            if errno == EINTR { continue }
            throw AttachmentImportError.unreadable
        }
        if count == 0 { break }
        if data.count + count > byteLimit {
            throw AttachmentImportError.tooLarge
        }
        data.append(buffer, count: count)
    }
    return data
}

/// Reads a file the system picker handed us, refusing an oversized one *before*
/// its bytes are read.
///
/// The picker returns a url outside the app's container, so the read is wrapped
/// in a security scope. Both the size probe and the read can fail for reasons
/// the user can act on (a file that has moved, an iCloud item not downloaded),
/// which is why they surface as `unreadable` rather than as a nil.
func loadPickedAttachmentFile(
    at url: URL,
    byteLimit: Int = attachmentImportByteLimit,
    allowStagingRoot: Bool = false
) throws -> PreparedAttachmentFile {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }

    switch validateRegularImportFile(at: url, byteLimit: byteLimit, allowStagingRoot: allowStagingRoot) {
    case .valid:
        break
    case .tooLarge:
        throw AttachmentImportError.tooLarge
    case .rejected:
        throw AttachmentImportError.unreadable
    }

    let data = try readRegularFileBytes(at: url, byteLimit: byteLimit)

    return PreparedAttachmentFile(
        fileName: sanitizedAttachmentFileName(url.lastPathComponent),
        contentType: attachmentContentType(forFileExtension: url.pathExtension),
        data: data)
}
