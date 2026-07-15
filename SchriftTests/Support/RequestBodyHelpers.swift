import Foundation

/// Reads a request's body whether it survived as `httpBody` or was moved into
/// `httpBodyStream`. `URLSession` relocates bodies into the stream, so any test
/// asserting on sent bytes must drain it.
func bodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while stream.hasBytesAvailable {
        let bytesRead = stream.read(&buffer, maxLength: bufferSize)
        if bytesRead > 0 {
            data.append(buffer, count: bytesRead)
        } else {
            break
        }
    }
    return data
}

/// Records the title each save actually PATCHed.
///
/// A save is two requests — `PATCH documents/{id}/content/` then `PATCH documents/{id}/`
/// — and it is the second one that carries the rename. Asserting only that "a save
/// happened" cannot tell a replay that adopted a co-author's rename from one that
/// silently reverted it, so any test about titles has to read this body. Lock-guarded
/// because stubs are delivered on `URLSession`'s protocol thread.
final class PatchedTitleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var titles: [String] = []

    /// Call from the `stubHandler` with every request; non-title requests are ignored.
    func record(_ request: URLRequest) {
        guard request.httpMethod == "PATCH",
            let url = request.url?.absoluteString, !url.hasSuffix("/content/"),
            let body = bodyData(from: request),
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: String],
            let title = json["title"]
        else { return }
        lock.lock()
        defer { lock.unlock() }
        titles.append(title)
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return titles
    }

    var last: String? { all.last }
}
