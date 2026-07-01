import Foundation

actor DocsAPIClient {
    private let baseURL: URL
    private let session: URLSession
    private let cookieProvider: @Sendable () -> [HTTPCookie]

    init(
        baseURL: URL,
        session: URLSession = .shared,
        cookieProvider: (@Sendable () -> [HTTPCookie])? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.cookieProvider = cookieProvider ?? { HTTPCookieStorage.shared.cookies(for: baseURL) ?? [] }
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(path: path, method: "GET", body: nil)
    }

    func send<T: Decodable>(path: String, method: String, body: Data?) async throws -> T {
        let data = try await performRequest(path: path, method: method, body: body)
        do {
            return try JSONDecoder.docsAPI.decode(T.self, from: data)
        } catch {
            throw DocsAPIError.decoding("\(error)")
        }
    }

    func sendVoid(path: String, method: String, body: Data?) async throws {
        _ = try await performRequest(path: path, method: method, body: body)
    }

    private func performRequest(path: String, method: String, body: Data?) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw DocsAPIError.network("Invalid path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if method != "GET" {
            if let token = csrfToken(from: cookieProvider()) {
                request.setValue(token, forHTTPHeaderField: "X-CSRFToken")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DocsAPIError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DocsAPIError.network("Response was not an HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            var headers: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    headers[key] = value
                }
            }
            throw DocsAPIErrorMapper.map(statusCode: httpResponse.statusCode, headers: headers)
        }

        return data
    }
}
