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
